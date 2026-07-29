defmodule Api.Messaging do
  @moduledoc """
  Comunicação **com o paciente** (doc 52) — o quarto plano, ao lado do tempo real, do toast e da
  caixa do sino (§1). Aqui o destinatário não tem login, o transporte é externo, a entrega é
  falível, custa por mensagem e **volta**.

  Como em `Api.Notifications`, os wrappers deste módulo centralizam o `in_clinic/2` (a GUC de
  tenant da RLS) na leitura; a escrita põe a GUC dentro da própria ação (`SetTenantGuc`).

  ## O mapa

    * `Api.Messaging.Message` — o registro do que foi (ou não foi) comunicado, por participante;
    * `Api.Messaging.OptOut` — quem pediu para parar, por destino;
    * `Api.Messaging.Templates` — o texto, como template + variáveis;
    * `Api.Messaging.Dispatch` — **o único lugar** que decide se uma mensagem sai, e por onde;
    * `Api.Messaging.SendJob` — o transporte, fora do request;
    * `Api.Messaging.ReplyToken` — o link assinado pelo qual o paciente responde.

  ## O que NÃO mora aqui

  Notificação in-app: é `Api.Notifications`, e a separação é deliberada (doc 52 §1).
  """
  use Ash.Domain, otp_app: :api

  import Api.Tenancy, only: [in_clinic: 2]

  require Ash.Query

  resources do
    resource Api.Messaging.Message do
      define :enqueue_message, action: :enqueue
      define :list_messages_for_appointment, action: :for_appointment, args: [:appointment_id]

      define :list_pending_messages,
        action: :pending_for_attendance,
        args: [:attendance_id, :kind]

      define :list_pending_messages_for_appointment,
        action: :pending_for_appointment,
        args: [:appointment_id]

      define :do_discard_message, action: :discard

      define :get_message, action: :read, get_by: [:id]
      define :get_message_by_provider_id, action: :by_provider_id, args: [:provider_message_id]
      define :do_mark_sent, action: :mark_sent
      define :do_advance_message, action: :advance
      define :do_record_reply, action: :record_reply
    end

    resource Api.Messaging.OptOut do
      define :register_opt_out, action: :registrar
      define :list_opt_outs, action: :vigentes, args: [:canal, :destino, :clinic_id]
      define :do_revoke_opt_out, action: :revogar
    end
  end

  @doc """
  A timeline de comunicação de um agendamento — o que a recepção lê no drawer (§6).

  Devolve as mensagens em ordem cronológica, já recortadas pelo papel de quem pergunta (o
  `profissional` só vê a própria coluna, pela preparation `OwnAgendaOnly`).

  **Não devolve o "nada enviado"**: aquele estado (§6) é *ausência* de mensagem, derivado do contato
  da ficha na hora da leitura — quem o monta é a fronteira, que tem os participantes à mão. Aqui
  só existe o que de fato foi registrado.
  """
  def timeline(%Api.Scope{} = scope, appointment_id) when is_binary(appointment_id) do
    in_clinic(scope, fn ->
      list_messages_for_appointment!(appointment_id, scope: scope)
    end)
  end

  @doc """
  Este destino pediu para parar neste canal?

  Consulta **global + clínica** numa query só (ver `OptOut`): opt-out de número compartilhado
  nasce global (C10/C11), e ignorá-lo seria continuar mandando para quem pediu para parar.

  Roda **fora** do `in_clinic` de propósito: `OptOut` não é por-tenant (é o único do projeto), e
  quem chama pode não ter GUC nenhuma — o webhook, por exemplo.

  `Ash.exists?` e não `list |> Enum.any?`: a pergunta é "existe?", e a lista trazia as dez colunas
  de todas as linhas casadas para jogar fora. O `exists?` emite `SELECT TRUE … LIMIT 1` — a mesma
  forma que o `ja_confirmada?/2` do `Notifier` já usava, no mesmo domínio.
  """
  def opted_out?(canal, destino, clinic_id) when is_binary(destino) do
    Api.Messaging.OptOut
    |> Ash.Query.for_read(:vigentes, %{canal: canal, destino: destino, clinic_id: clinic_id},
      authorize?: false
    )
    |> Ash.exists?(authorize?: false)
  end

  @doc """
  Registra um opt-out, sem duplicar.

  Idempotente porque as fontes repetem (§10.2): o Resend reentrega o mesmo `complained` se o
  webhook demorar, e o paciente pode clicar duas vezes no descadastro. Um segundo registro não
  mudaria o efeito, mas encheria a trilha de linhas iguais.
  """
  def opt_out(canal, destino, origem, opts \\ []) when is_binary(destino) do
    clinic_id = Keyword.get(opts, :clinic_id)

    if opted_out?(canal, destino, clinic_id) do
      :ok
    else
      register_opt_out!(
        %{
          canal: canal,
          destino: destino,
          origem: origem,
          motivo: Keyword.get(opts, :motivo),
          clinic_id: clinic_id
        },
        authorize?: false
      )

      :ok
    end
  end

  @doc """
  O paciente voltou a aceitar (§10.1, regra 3) — pedido no balcão, registrado com nome e hora.

  Revoga **todos** os opt-outs vigentes daquele destino no canal, inclusive o global: quem pede
  para voltar a receber não está pedindo "só nesta clínica", está desfazendo o "pare".
  """
  def revoke_opt_out(%Api.Scope{user: user} = scope, canal, destino) do
    canal
    |> list_opt_outs!(destino, scope.clinic_id, authorize?: false)
    |> Enum.each(&do_revoke_opt_out!(&1, %{revogado_por_id: user && user.id}, authorize?: false))

    :ok
  end
end
