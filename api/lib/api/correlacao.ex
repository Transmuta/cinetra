defmodule Api.Correlacao do
  @moduledoc """
  Carrega o `request_id` da requisição corrente para o job que ela enfileira (doc 62 §12).

  ## O buraco que isto fecha

  > **Atualizado em 2026-07-29:** o projeto passou a ter tracing (doc 76), e este módulo **não foi
  > substituído**. Os dois identificadores convivem de propósito: o `trace_id` abre a árvore e
  > vive 7 dias no Tempo; o `request_id` vive **30 dias** no Loki, existe quando o trace está
  > desligado (dev, CI, qualquer instalação sem `OTEL_EXPORTER_OTLP_ENDPOINT`) e é o que sobra
  > quando o span não é amostrado. Ver `Api.Tracing`.

  O `request_id` atravessa as fronteiras da requisição.

  Ele já atravessava uma requisição inteira da API (o `Plug.RequestId` o põe no
  `Logger.metadata`, e o `ApiWeb.RequestLogger` o carimba no evento). Onde ele se perdia era na
  passagem para a fila: a linha de job do Oban traz `queue`, `worker`, `duration` e `queue_time`,
  mas nada que a ligue a quem a enfileirou.

  O efeito prático era não conseguir responder a pergunta que justificou ligar o logger do Oban
  (doc 62 §1): *"por que o lembrete não saiu na terça"*. Via-se a requisição, via-se o job, e não
  havia o que os ligasse — sobrava o `clinic_id` dentro dos `args`, que agrupa mas não identifica.

  ## Por que `meta` e não `args`

  `args` é entrada do worker: entra na chave de unicidade, é o que o `perform/1` casa por padrão e
  o que os testes comparam com `assert_enqueued`. Um campo de observabilidade ali mudaria o
  contrato de cinco workers e a chave de unicidade junto — dois lembretes idênticos de requisições
  diferentes deixariam de colidir.

  `meta` é exatamente o campo para isto: não participa de unicidade, não chega ao `perform/1`, e o
  logger padrão do Oban **já o imprime**. Ou seja, o id aparece no log sem uma linha de código a
  mais em nenhum worker.

  ## Ausência é resposta válida

  Job enfileirado por cron ou por outro job não tem `request_id` — não houve requisição. Nesse caso
  não se grava `meta` nenhum, em vez de gravar `nil`: um campo presente e vazio parece correlação
  e não correlaciona nada, o que é pior que a ausência, porque quem lê o log acredita nele.
  """

  @doc """
  Opções para `Oban.Worker.new/2` com o `request_id` corrente no `meta`.

  Recebe e devolve a keyword list de opções do chamador, para que quem já passava `scheduled_at`
  (a janela de silêncio do `SendJob`) não precise saber deste módulo além da chamada.

      %{"clinic_id" => id}
      |> MeuWorker.new(Api.Correlacao.opts(scheduled_at: quando))
      |> Oban.insert()
  """
  @spec opts(keyword()) :: keyword()
  def opts(opts \\ []) when is_list(opts) do
    case Logger.metadata()[:request_id] do
      nil -> opts
      id -> Keyword.update(opts, :meta, %{"request_id" => id}, &Map.put(&1, "request_id", id))
    end
  end
end
