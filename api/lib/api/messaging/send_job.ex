defmodule Api.Messaging.SendJob do
  @moduledoc """
  O transporte, fora do request (doc 52 §4).

  ## Por que job, e não envio síncrono

  Três razões, e a terceira é a que decide:

    * o provider é uma chamada de rede que pode demorar ou cair, e ninguém deve esperar por ela
      para ver "agendamento criado";
    * a criação de um agendamento de turma dispara N mensagens — N chamadas HTTP em série no
      caminho do clique;
    * **a janela de silêncio** (§7) precisa *adiar*, e adiar é o que uma fila faz nativamente
      (`scheduled_at`). Síncrono, a única alternativa seria descartar.

  ## Fila `notifications`, não `housekeeping`

  Mesmo critério do `SlotOpenedJob`: a poda diária varre clínica a clínica e pode ocupar os dois
  slots de `housekeeping` por minutos. Confirmação que chega depois do paciente já ter saído de
  casa não vale nada.

  ## Três passos, e o do meio **fora** de transação

  Ler a mensagem exige a GUC (RLS); gravar o resultado também. **Entregar não.** A primeira versão
  envolvia os três num `with_clinic/2` só, e o efeito foi medido no bate-volta: a conexão fica
  `idle in transaction` pelo tempo do round-trip ao provider — com um adapter que dorme 4 s,
  `pg_stat_activity` mostrou a conexão presa segurando a query de leitura. Com `notifications: 5`,
  cinco envios lentos simultâneos seguram cinco conexões do pool pelo tempo da rede alheia.

  Agora são três passos: lê sob GUC, **sai**, entrega, e volta sob GUC para gravar. O preço é uma
  transação a mais por envio; o que se compra é o pool não depender da latência de terceiro.

  ## Retentativa, e o que ela não pode causar

  `max_attempts: 3` com o backoff padrão do Oban. O risco de retentar um envio é **mensagem
  duplicada** — e ele é real: se o provider aceitou e a resposta se perdeu, a retentativa manda de
  novo. A guarda é o estado: o job só envia quando a mensagem ainda está `:pendente`. Uma que já
  virou `:enviado` (porque a tentativa anterior gravou) sai pelo caminho de sucesso sem tocar no
  transporte.

  Isso não fecha a janela entre "o provider aceitou" e "gravamos `:enviado`" — nada fecha, sem
  idempotência do lado do provider. O Resend aceita `idempotency_key`, e usá-la é o passo que
  falta para essa janela sumir; fica anotado como o refinamento óbvio, não como pendência que
  bloqueia a fatia (uma confirmação duplicada é constrangedora, não perigosa).
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  require Logger

  alias Api.Messaging
  alias Api.Messaging.Message
  alias Api.Messaging.ReplyToken
  alias Api.Messaging.Templates
  alias Api.Messaging.Transport

  @doc """
  Enfileira o envio de uma mensagem.

  `:agendar_para` é o instante em que ela pode sair (a janela de silêncio do `Dispatch`); `nil`
  significa agora.
  """
  def enqueue(%{id: id, clinic_id: clinic_id}, opts \\ []) do
    %{"clinic_id" => clinic_id, "message_id" => id}
    |> new(agendamento(Keyword.get(opts, :agendar_para)))
    |> Oban.insert()
  end

  defp agendamento(nil), do: []
  defp agendamento(%DateTime{} = quando), do: [scheduled_at: quando]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clinic_id" => clinic_id, "message_id" => message_id}}) do
    case ler(clinic_id, message_id) do
      {:ok, %Message{} = message} -> enviar(message)
      _ -> :ok
    end

    :ok
  end

  # `tenant:` **e** GUC, e as duas por motivos diferentes: o `tenant:` é o filtro do Ash (sem ele a
  # leitura de recurso por-tenant nem roda — levanta "require a tenant"), e a GUC é o que a RLS do
  # Postgres exige. Faltar o primeiro dá erro alto; faltar o segundo devolve **vazio calado** sob
  # `movimento_app`, e o job "funciona" sem enviar nada — invisível no `mix test`, onde o sandbox
  # bypassa RLS. Os dois já custaram fatia (doc 09, materialização de pacote).
  defp ler(clinic_id, message_id) do
    Api.Repo.with_clinic(clinic_id, fn ->
      Messaging.get_message(message_id,
        tenant: clinic_id,
        authorize?: false,
        not_found_error?: false
      )
    end)
    |> elem(1)
  end

  # Já enviada: a tentativa anterior chegou ao provider e gravou. Retentar aqui duplicaria a
  # mensagem para o paciente. Ver o moduledoc.
  defp enviar(%Message{status: status}) when status != :pendente, do: :ok

  defp enviar(%Message{} = message) do
    case render(message) do
      {:ok, corpo} -> entregar(message, corpo)
      :error -> falhar(message, "template desconhecido: #{message.template}")
    end
  end

  # O link de resposta é montado **no envio**, não na gravação: ele depende do id da mensagem,
  # que só existe depois do insert. Guardá-lo em `vars` também duplicaria um dado derivável.
  defp render(%Message{} = message) do
    vars = Map.put(message.vars, "link", ReplyToken.url(message.id))

    Templates.render_email(message.template, vars)
  end

  defp entregar(%Message{} = message, corpo) do
    case Transport.entregar(message, corpo) do
      {:ok, provider, provider_id} ->
        # Volta para dentro de uma transação com GUC só para gravar — a entrega já aconteceu.
        Api.Repo.with_clinic(message.clinic_id, fn ->
          Messaging.do_mark_sent!(
            message,
            %{provider: provider, provider_message_id: provider_id},
            tenant: message.clinic_id,
            authorize?: false
          )
        end)

        :ok

      {:error, motivo} ->
        falhar(message, motivo)
    end
  end

  # A falha é gravada e o job **não** levanta: o retry do Oban existe para erro transitório de
  # rede (que o transporte devolve como exceção, e aí o job estoura de verdade), não para
  # "endereço inválido", que vai falhar igual nas três tentativas. Gravar e sair deixa o motivo
  # na tela da recepção, que é quem consegue corrigir.
  defp falhar(%Message{} = message, motivo) do
    Api.Repo.with_clinic(message.clinic_id, fn ->
      Messaging.do_advance_message!(
        message,
        %{novo_status: :falhou, erro: to_string(motivo)},
        tenant: message.clinic_id,
        authorize?: false
      )
    end)

    Logger.warning("mensagem #{message.id} falhou: #{motivo}")

    :ok
  end
end
