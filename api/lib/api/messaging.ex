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

      define :list_attendance_messages, action: :for_attendance, args: [:attendance_id]

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

    resource Api.Messaging.WebhookEvent do
      define :register_webhook_event, action: :registrar
      define :list_webhook_events, action: :por_corpo, args: [:provider, :digest]
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

  **A idempotência é do banco, não daqui** (doc 96, A-5). Isto já foi um `if opted_out?, do: :ok,
  else: gravar` — *check-then-act*, com a janela clássica no meio: duas reentregas simultâneas do
  mesmo evento leem "ainda não" as duas e gravam as duas. A ação `:registrar` é upsert sobre a
  identity `:vigente_por_destino`, então quem resolve o empate é o `ON CONFLICT`, que não tem
  janela. De quebra some uma leitura por mensagem no caminho do webhook.
  """
  def opt_out(canal, destino, origem, opts \\ []) when is_binary(destino) do
    register_opt_out!(
      %{
        canal: canal,
        destino: destino,
        origem: origem,
        motivo: Keyword.get(opts, :motivo),
        clinic_id: Keyword.get(opts, :clinic_id)
      },
      authorize?: false
    )

    :ok
  end

  @doc """
  O opt-in **por paciente**: revoga o "pare" de todos os contatos da ficha, nos dois canais.

  É a contrapartida obrigatória do opt-out (LGPD, art. 8º §5 — revogar o consentimento tem de ser
  tão simples quanto dá-lo). Sem isto, um paciente que respondeu "SAIR" e depois pediu no balcão
  para voltar a receber só era desbloqueado por `psql` (doc 96, M-4).

  Os destinos saem de `Dispatch.destinos/1`, já canonicalizados — revogar por um número escrito de
  outro jeito não acha a linha gravada.
  """
  def revoke_patient_opt_outs(%Api.Scope{} = scope, patient) do
    patient
    |> Api.Messaging.Dispatch.destinos()
    |> Enum.each(fn {canal, destino} -> revoke_opt_out(scope, canal, destino) end)

    :ok
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

  @doc """
  Este corpo de webhook já foi processado? (doc 96, S-7)

  Devolve `:novo` na primeira vez que este corpo é visto e `:repetido` daí em diante. A chave é o
  SHA-256 do **corpo cru** — ver `Api.Messaging.WebhookEvent` para por que não é um id do provider.

  Quem chama é a fronteira, que é quem tem o corpo cru; e ela chama **depois** de processar, não
  antes: se marcasse antes, uma falha no processamento consumiria a única chance de o provider
  reentregar aquele evento. Como o efeito de todo evento é idempotente, processar duas vezes por
  concorrência é inofensivo — o que esta barreira existe para impedir é o replay *muito depois*,
  contra o qual a assinatura da Zernio não protege.
  """
  def webhook_visto(provider, corpo) when is_binary(provider) and is_binary(corpo) do
    digest = :sha256 |> :crypto.hash(corpo) |> Base.encode16(case: :lower)

    case list_webhook_events!(provider, digest, authorize?: false) do
      [_ja_visto | _] ->
        :repetido

      [] ->
        # A leitura decide; a escrita é upsert só para não estourar `unique_violation` se duas
        # reentregas simultâneas passarem pela leitura juntas. Nesse empate as duas processam — e
        # tudo bem, porque todo efeito de webhook é idempotente. O que esta barreira existe para
        # impedir é o replay **muito depois**, onde a janela de concorrência não é o problema.
        register_webhook_event!(%{provider: provider, digest: digest}, authorize?: false)
        :novo
    end
  end
end
