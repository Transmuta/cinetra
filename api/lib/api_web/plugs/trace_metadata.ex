defmodule ApiWeb.Plugs.TraceMetadata do
  @moduledoc """
  Põe o `trace_id` da requisição no metadata do Logger, para toda linha do processo (doc 76).

  ## O que isto compra

  É a costura entre os dois bancos de observabilidade. O `derivedFields` do datasource do Loki
  (`deploy/observability/grafana-datasources.yml`) procura `trace_id` na linha de log e oferece o
  botão **"Ver trace"**; o `tracesToLogsV2` do datasource do Tempo faz o caminho de volta. Os dois
  sentidos dependem deste campo — quebrou aqui, quebraram os dois, e o sintoma é ausência de
  botão, que ninguém percebe.

  ## Por que um plug, e não um campo no `RequestLogger`

  Porque `Logger.metadata/1` vale para o **processo inteiro**: carimbado aqui, ele aparece não só
  na linha da requisição, mas em todo log que a requisição produzir no caminho — o erro do
  controller, o aviso do domínio, a linha do adaptador de storage. Numa investigação é
  exatamente o contrário do que se quer ter: a linha que interessa costuma ser a do meio, não a
  do fim.

  Vai logo depois do `Plug.RequestId`, que faz a mesma coisa com o `request_id`. Os dois
  identificadores convivem de propósito: o `request_id` continua sendo o que atravessa para o job
  do Oban (`Api.Correlacao`) e o que sobrevive por 30 dias no Loki; o `trace_id` é o que abre a
  árvore, e só existe por 7 dias.

  ## Sem span, sem campo

  Requisição que chega com o exportador desligado (dev sem stack de observabilidade) não tem span
  ativo, e aqui não se carimba nada — em vez de gravar `nil` ou `"desconhecido"`. Pelo mesmo
  motivo de `Api.Correlacao`: um campo presente e vazio parece correlação e não correlaciona nada,
  e quem lê o log acredita nele.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Api.Tracing.trace_id() do
      nil ->
        conn

      id ->
        Logger.metadata(trace_id: id)
        conn
    end
  end
end
