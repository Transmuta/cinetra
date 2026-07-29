defmodule Api.Tracing do
  @moduledoc """
  Liga o OpenTelemetry: quatro handlers no boot, e o `trace_id` para o log (doc 76).

  ## O que o trace responde e o log não

  O log já dizia que `GET /api/agenda` demorou 3 s, e as métricas já diziam que a máquina estava
  tranquila. O que faltava era **onde** foram os 3 s: qual consulta, quantas vezes, em que ordem
  — com a linha do BFF por cima, porque o trace nasce no Node e atravessa para cá.

  ## Isto reverte uma decisão, de propósito

  O [doc 62 §12](../../../docs/62-plano-de-logs.md) e o [doc 79](../../../docs/79-signoz-vs-hyperdx.md)
  recusaram tracing, e o argumento central era que "todo atributo de span é dado exportado" — o
  que pesa num produto com dado de saúde. O argumento valia contra **SaaS**. Não vale contra o
  desenho de hoje: o span nasce aqui, passa pelo Alloy que já roda ao lado e para no volume do
  Tempo, no mesmo perímetro em que o log está desde o começo.

  O que sobra do argumento é o VOLUME de detalhe, e a resposta a isso é a poda — que mora no
  `alloy.alloy`, num lugar só, valendo para os dois serviços.

  ## Por que quatro, e não um

  Cada um cobre um trecho do caminho que os outros não enxergam:

    * **Bandit** abre o span do servidor. É ele quem lê o `traceparent` do BFF — sem ele os dois
      serviços viram dois traces órfãos;
    * **Phoenix** acrescenta o que só o framework sabe: rota do router, controller, action. Com
      adapter `:bandit` ele NÃO cria span, só enriquece o de cima (por isso os dois);
    * **Ecto** é onde o tempo costuma estar de fato;
    * **Oban** faz o trace atravessar a fila — o mesmo buraco que `Api.Correlacao` fechou com o
      `request_id`, agora com a árvore inteira.

  ## Desligado por padrão

  Sem `OTEL_EXPORTER_OTLP_ENDPOINT` o exportador é `:none` (ver `config/runtime.exs`): os spans
  nascem, medem e morrem em memória, custando um punhado de microssegundos. É o que mantém dev,
  teste e qualquer instalação sem stack de observabilidade exatamente como estavam — ligar trace
  não pode ser um pré-requisito para rodar o projeto.
  """

  @doc """
  Pendura os handlers de `:telemetry` das quatro fontes. Chamado uma vez, no boot.
  """
  def setup do
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit)

    # `db_statement: :enabled` — o SQL vai no span. É a escolha da largada ("liga com o padrão e
    # poda depois"), e ela é menos arriscada do que parece: o Ecto emite SQL **parametrizado**
    # (`WHERE cpf = $1`), então o valor não viaja junto. O que viaja é a forma da consulta, que é
    # justamente o que se quer ler quando um endpoint fica lento.
    OpentelemetryEcto.setup([:api, :repo], db_statement: :enabled)

    OpentelemetryOban.setup()

    :ok
  end

  @doc """
  `trace_id` do span corrente em hexa, ou `nil` quando não há span.

  É o que costura log e trace: o `derivedFields` do datasource do Loki procura exatamente este
  campo na linha para oferecer o botão "Ver trace". Sem ele os dois bancos ficam lado a lado sem
  se falarem — e nada avisa, porque o botão apenas não aparece.
  """
  @spec trace_id() :: String.t() | nil
  def trace_id do
    case :otel_tracer.current_span_ctx() do
      :undefined -> nil
      ctx -> :otel_span.hex_trace_id(ctx)
    end
  end
end
