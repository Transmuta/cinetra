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
  alias Api.Messaging.Falhas
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
    |> new(Api.Correlacao.opts(agendamento(Keyword.get(opts, :agendar_para))))
    |> Oban.insert()
  end

  defp agendamento(nil), do: []
  defp agendamento(%DateTime{} = quando), do: [scheduled_at: quando]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"clinic_id" => clinic_id, "message_id" => message_id}}) do
    case ler(clinic_id, message_id) do
      {:ok, %Message{} = message} ->
        enviar(message)

      # A mensagem sumiu (poda, cancelamento). Nada a fazer, e não é erro.
      {:ok, nil} ->
        :ok

      # Erro de banco/RLS na LEITURA. Antes caía no mesmo `_ -> :ok` do caso acima: o job era
      # marcado `completed`, a mensagem nunca saía, e não havia retry nem log — silêncio total
      # sobre uma mensagem que a recepção acha que está na fila (doc 96, B-9). Devolver `{:error,
      # _}` é o que faz o Oban retentar, que é o comportamento certo para falha transitória.
      {:error, motivo} ->
        Logger.error("SendJob: falha ao ler a mensagem",
          message_id: message_id,
          clinic_id: clinic_id,
          motivo: inspect(motivo)
        )

        {:error, motivo}
    end
  end

  # `tenant:` **e** GUC, e as duas por motivos diferentes: o `tenant:` é o filtro do Ash (sem ele a
  # leitura de recurso por-tenant nem roda — levanta "require a tenant"), e a GUC é o que a RLS do
  # Postgres exige. Faltar o primeiro dá erro alto; faltar o segundo devolve **vazio calado** sob
  # `cinetra_app`, e o job "funciona" sem enviar nada — invisível no `mix test`, onde o sandbox
  # bypassa RLS. Os dois já custaram fatia (doc 09, materialização de pacote).
  #
  # O `elem(1)` que estava aqui apagava a diferença entre as duas: `with_clinic/2` é
  # `Repo.transaction/1`, e num rollback `elem(1)` devolve o *reason* cru, que o `case` do
  # `perform/1` engolia como "não achei". Separar "não existe" de "não consegui ler" é o conserto
  # de B-9/B-10 — e virou `Api.Repo.unwrap/1` (E-2), que é a mesma decisão escrita uma vez só, em
  # vez do `case` de cinco cláusulas que vivia aqui.
  defp ler(clinic_id, message_id) do
    Api.Repo.with_clinic(clinic_id, fn ->
      Messaging.get_message(message_id,
        tenant: clinic_id,
        authorize?: false,
        not_found_error?: false
      )
    end)
    |> Api.Repo.unwrap()
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
  #
  # No WhatsApp vai o **token**, não a URL: o domínio está congelado dentro do botão do template
  # aprovado (`https://cinetra.com.br/confirmar/{{1}}`), e o que se manda é só o sufixo. Mandar a
  # URL inteira produziria `.../confirmar/https://cinetra.com.br/confirmar/<token>`, um link
  # quebrado que só aparece clicando — a API aceita, porque a contagem de parâmetros bate.
  defp render(%Message{canal: :whatsapp} = message) do
    vars = Map.put(message.vars, "token", ReplyToken.sign(message.id))

    Templates.render_whatsapp(message.template, vars)
  end

  defp render(%Message{} = message) do
    vars = Map.put(message.vars, "link", ReplyToken.url(message.id))

    Templates.render_email(message.template, vars)
  end

  defp entregar(%Message{} = message, corpo) do
    case Transport.entregar(message, corpo) do
      {:ok, provider, provider_id} ->
        marcar_enviada(message, provider, provider_id)

      {:error, motivo} ->
        falhar(message, motivo)
    end
  end

  # A entrega **já aconteceu** quando esta função roda — o paciente já recebeu, e no WhatsApp a
  # clínica já pagou. Daí as duas regras aqui:
  #
  #   1. o resultado da transação é casado, não descartado. Antes o `with_clinic` era chamado por
  #      efeito colateral e o `:ok` vinha logo abaixo, incondicional: um `{:error, _}` (deadlock,
  #      timeout de pool, RLS) saía como sucesso e a mensagem ficava `:pendente` para sempre,
  #      entregue e invisível para a recepção (doc 96, B-3);
  #
  #   2. a falha ao GRAVAR **não** propaga. Se ela subisse, o `perform/1` estouraria, o Oban
  #      reenfileiraria (`max_attempts: 3`), a mensagem ainda estaria `:pendente` — o guard de
  #      `enviar/1` não pegaria — e o `Transport.entregar` rodaria de novo: **segunda mensagem
  #      paga para o mesmo número**. Entre "reenviar ao paciente" e "registrar o desencontro no
  #      log", o log é o mal menor, e é o único que não custa dinheiro nem constrange o paciente.
  #
  # O que sobra é um alerta alto o bastante para virar chamado: a linha ficou `:pendente` no banco
  # e a mensagem saiu no mundo. É a inconsistência que o `provider_message_id` do webhook resolve
  # depois, e que sem log ninguém descobriria.
  # **Sem `with_clinic/2` em volta** (doc 96, B-11): `:mark_sent` carrega `SetTenantGuc`, então a
  # GUC já está posta dentro da transação da própria ação. A de fora não acrescentava tenancy — e
  # acrescentava a armadilha que `Api.Tenancy` documenta: numa falha, o rollback do Ash arrebenta a
  # transação externa, e o erro chega deformado em vez de como exceção. O `rescue` abaixo já é o
  # caminho de erro deste ponto, e agora é o único.
  defp marcar_enviada(%Message{} = message, provider, provider_id) do
    Messaging.do_mark_sent!(
      message,
      %{provider: provider, provider_message_id: provider_id},
      tenant: message.clinic_id,
      authorize?: false
    )

    :ok
  rescue
    erro -> alertar_entregue_sem_registro(message, provider, provider_id, erro)
  end

  defp alertar_entregue_sem_registro(message, provider, provider_id, motivo) do
    Logger.error(
      "mensagem ENTREGUE mas não registrada: o provider aceitou e a gravação de :enviado falhou. " <>
        "A linha segue :pendente e NÃO deve ser reenviada.",
      message_id: message.id,
      clinic_id: message.clinic_id,
      canal: message.canal,
      provider: provider,
      provider_message_id: provider_id,
      motivo: inspect(motivo)
    )

    :ok
  end

  # A falha é gravada e o job **não** levanta: o retry do Oban existe para erro transitório de
  # rede (que o transporte devolve como exceção, e aí o job estoura de verdade), não para
  # "endereço inválido", que vai falhar igual nas três tentativas. Gravar e sair deixa o motivo
  # na tela da recepção, que é quem consegue corrigir.
  defp falhar(%Message{} = message, motivo) do
    # Sem `with_clinic/2`, pela mesma razão de `marcar_enviada/3`: `:advance` já carrega
    # `SetTenantGuc`. A transação de fora só existia por hábito — o resultado dela era descartado,
    # e uma exceção atravessava os dois níveis igual.
    Messaging.do_advance_message!(
      message,
      %{novo_status: :falhou, erro: to_string(motivo)},
      tenant: message.clinic_id,
      authorize?: false
    )

    # **A frase classificada, nunca o texto cru** (doc 62 §7.3). O `motivo` que chega aqui é o que
    # o provider devolveu, e num bounce de e-mail ele normalmente embute o destinatário —
    # `550 5.1.1 <paciente@exemplo.com>: Recipient address rejected`. Logar isso põe PII de
    # titular na agregação de log, que é justamente o sistema com a retenção mais frouxa e o
    # público mais amplo do projeto.
    #
    # `para_tela/1` resolve para uma lista **fechada** de frases (as nossas ou as do @regras), então
    # é PII-free por construção, não por vigilância. O texto cru continua onde deve: na coluna
    # `erro`, sob RLS, visível só para a clínica dona do paciente — que é quem precisa dele.
    Logger.warning("mensagem #{message.id} falhou: #{Falhas.para_tela(to_string(motivo))}")

    :ok
  end
end
