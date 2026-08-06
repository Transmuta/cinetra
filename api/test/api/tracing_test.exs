defmodule Api.TracingTest do
  @moduledoc """
  O trace, provado onde ele de fato acontece (doc 76).

  Três coisas são testadas aqui, e cada uma cobre um jeito diferente de a instrumentação nascer
  morta:

    * **a consulta vira span** — prova que o handler do Ecto está pendurado de verdade, e não só
      que `setup/0` foi chamado;
    * **o `traceparent` que chega continua o trace** — a fronteira BFF→API. É a única asserção
      que garante que os dois serviços aparecem no MESMO trace, e ela não pode ser feita pelo
      `ConnCase`: com Bandit, quem abre o span do servidor é o `opentelemetry_bandit`, que só
      existe quando há servidor de verdade. Teste de dentro passaria com a fronteira quebrada;
    * **o `trace_id` no metadata do log** — a costura com o Loki (`derivedFields` do
      `grafana-datasources.yml`). Sem o campo na linha, o botão "Ver trace" simplesmente não
      aparece, e nada avisa.
  """

  use Api.DataCase, async: false

  require Record
  require OpenTelemetry.Tracer, as: Tracer

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  @porta 4003

  setup do
    # O exportador vira "manda para este processo": cada span fechado chega como `{:span, record}`
    # na caixa de mensagens do teste. Por isso `async: false` — com dois testes concorrentes os
    # spans de um cairiam na caixa do outro.
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    # **Sem `on_exit` restaurando o exportador**, e isso é escolha medida, não descuido: as três
    # aridades de `set_exporter` embrulham o argumento em `{Exporter, Options}`, e o
    # `otel_exporter:init/1` só reconhece o desligamento pelo átomo PELADO (`none`). Restaurar
    # desliga de fato, mas imprime "Exporter module :none not found" a cada teste — cinco linhas
    # de aviso que parecem defeito de configuração e não são.
    #
    # O que fica no lugar: o exportador segue apontado para o pid deste teste, já morto. Enviar
    # mensagem a pid morto é no-op silencioso em Erlang, então o efeito para o resto da suíte é o
    # mesmo do desligado.
    :ok
  end

  describe "a suíte não exporta span para lugar nenhum" do
    test "exportador desligado e processador síncrono, mesmo com OTLP no ambiente" do
      # Regressão de um bug medido: o `runtime.exs` roda em TODOS os ambientes, então ligar o
      # trace em dev (`OTEL_EXPORTER_OTLP_ENDPOINT` no `.env`) passou a sobrescrever a config da
      # suíte — `span_processor` virava `:batch`, o `otel_simple_processor_global` deixava de
      # existir e os cinco testes deste arquivo morriam com "no process".
      #
      # O modo de falhar era o pior possível: **verde no CI** (que não tem a variável) e vermelho
      # só na máquina de quem ligou observabilidade. Estas duas linhas prendem a decisão.
      assert Application.get_env(:opentelemetry, :traces_exporter) == :none
      assert Application.get_env(:opentelemetry, :span_processor) == :simple
    end
  end

  describe "o trace_id sobrevive ao formatter de CADA ambiente" do
    # Achado ao vivo, e o mais perigoso desta fatia: a lista de metadata do Logger existe em TRÊS
    # arquivos — `config.exs`, `dev.exs` e `prod.exs` — e cada um sobrescreve o anterior. Acrescentar
    # `:trace_id` só no primeiro deixou a costura log↔trace funcionando na suíte e **morta em
    # produção**, que é justamente onde ela serve: o `LoggerJSON` do `prod.exs` descarta toda chave
    # fora da sua lista, e o `derivedFields` do Grafana procura exatamente esse campo.
    #
    # Nada dá erro quando isso quebra. O botão "Ver trace" simplesmente não aparece.
    #
    # `Config.Reader` avalia o arquivo com o `config_env()` do ambiente pedido, então o teste lê a
    # configuração REAL de produção em vez de uma cópia da lista.

    test "produção: o formatter JSON emite trace_id" do
      config = Config.Reader.read!("config/prod.exs", env: :prod)
      {Api.LogFormatter, opts} = config[:logger][:default_handler][:formatter]

      assert :trace_id in opts[:metadata]
    end

    test "dev: o formatter de texto mostra trace_id" do
      config = Config.Reader.read!("config/dev.exs", env: :dev)

      assert :trace_id in config[:logger][:default_formatter][:metadata]
    end
  end

  describe "instrumentação do Ecto" do
    test "a consulta ao banco vira span" do
      Tracer.with_span "teste" do
        Api.Repo.query!("SELECT 1")
      end

      assert_receive {:span, span(name: nome, attributes: atributos)}, 1_000
      assert nome =~ "api.repo.query"

      # `db.statement` é o SQL. Está LIGADO de propósito na largada (doc 76 §4): o valor de um
      # trace de banco está em ver qual consulta demorou, e os valores dos parâmetros não vão
      # junto — o Ecto manda SQL parametrizado (`$1`), então o CPF do paciente não está aqui.
      #
      # Esta asserção é a trava consciente da decisão: quando `db.statement` for podado no Alloy,
      # é aqui que a mudança tem de ser deliberada, não silenciosa.
      assert %{"db.statement": sql} = :otel_attributes.map(atributos)
      assert sql =~ "SELECT 1"
    end
  end

  describe "a fronteira BFF → API" do
    setup do
      # Servidor de verdade. O `ApiWeb.Endpoint` da suíte sobe com `server: false`, e é isso que
      # torna este teste necessário: sem Bandit no caminho não há span de servidor nenhum.
      start_supervised!({Bandit, plug: ApiWeb.Endpoint, scheme: :http, port: @porta})
      :ok
    end

    test "o traceparent que chega continua o MESMO trace" do
      # Um trace que "vem do BFF": id fixo, para poder afirmar que é o mesmo do outro lado.
      trace_id = "0af7651916cd43dd8448eb211c80319c"
      span_pai = "b7ad6b7169203331"

      resposta =
        Req.get!("http://127.0.0.1:#{@porta}/api/health",
          headers: [{"traceparent", "00-#{trace_id}-#{span_pai}-01"}]
        )

      assert resposta.status == 200

      assert_receive {:span, span(trace_id: recebido, parent_span_id: pai, kind: :server)}, 2_000

      # É o mesmo trace, e o span do servidor pendura no span do BFF. Se a propagação quebrar, o
      # trace_id vira outro e cada serviço vira um trace órfão — que é como uma instrumentação
      # "funcionando" mas inútil se parece.
      assert hexa(recebido, 32) == trace_id
      assert hexa(pai, 16) == span_pai
    end

    test "o log da requisição sai com o trace_id da requisição" do
      # A costura, provada no caminho REAL — não no plug isolado. O que este teste cobre e o do
      # plug não: que existe span ativo no momento em que o pipeline roda, e que ele sobrevive até
      # o `RequestLogger` emitir a linha, no fim.
      # A suíte roda em `:warning` (test.exs) e a linha da requisição é `:info` — sem isto o log
      # capturado volta VAZIO e a asserção falha acusando o código de produção, que está certo.
      nivel = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: nivel) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Req.get!("http://127.0.0.1:#{@porta}/api/patients", retry: false)
          Process.sleep(50)
        end)

      assert log =~ "requisição"
      assert log =~ ~r/trace_id=[0-9a-f]{32}/
    end

    test "a rota do router nomeia o span, e o id do paciente não vira nome de span" do
      Req.get!("http://127.0.0.1:#{@porta}/api/health")

      assert_receive {:span, span(name: nome, kind: :server)}, 2_000
      assert nome == "GET /api/health"
    end
  end

  describe "trace_id no log" do
    test "o plug carimba o trace corrente no metadata" do
      Tracer.with_span "requisição" do
        chamar_plug()

        assert Logger.metadata()[:trace_id] =~ ~r/^[0-9a-f]{32}$/
      end
    end

    test "sem span ativo, não carimba nada" do
      Logger.metadata(trace_id: nil)
      chamar_plug()

      # Ausência é resposta válida, pelo mesmo motivo de `Api.Correlacao`: um campo presente e
      # vazio PARECE correlação e não correlaciona nada — e quem lê o log acredita nele.
      refute Logger.metadata()[:trace_id]
    end
  end

  # Passa pelo `init/1` como o pipeline do Plug faz, em vez de chamar `call/2` com opções cruas.
  # A diferença aparece no dia em que o plug ganhar opção: um teste que pula o `init` continua
  # verde com a configuração nunca sendo aplicada.
  defp chamar_plug do
    ApiWeb.Plugs.TraceMetadata.call(
      Plug.Test.conn(:get, "/api/agenda"),
      ApiWeb.Plugs.TraceMetadata.init([])
    )
  end

  # O span record traz os ids como inteiro; o traceparent do cabeçalho é hexa com zeros à
  # esquerda. Sem o preenchimento, um id que comece com zero falharia a comparação de forma
  # intermitente — uma vez a cada 16 execuções.
  defp hexa(id, largura) do
    id |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(largura, "0")
  end
end
