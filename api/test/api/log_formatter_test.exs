defmodule Api.LogFormatterTest do
  @moduledoc """
  O teste que nasceu do painel vazio (doc 99).

  Todo painel de 4xx do Grafana abria "No data" em produção com o log inteiro presente no Loki.
  A causa não estava na consulta: o `LoggerJSON.Formatters.Basic` **aninha** o metadata sob a
  chave `metadata`, e o `| json` do Loki achata objeto aninhado com `_` — os rótulos que existiam
  eram `metadata_status` e `metadata_route`, e os painéis perguntavam por `status` e `route`.

  Consulta certa sobre campo inexistente devolve zero linhas, não erro. O sintoma é um painel
  vazio, indistinguível de "não houve 4xx" — e ninguém desconfia.

  Por isso as asserções daqui são sobre a **posição** do campo na linha, não sobre o valor. É a
  posição que o Loki transforma em rótulo, e é ela que quebrou.
  """

  use ExUnit.Case, async: true

  # A lista que vale em produção (`config/prod.exs`). Repetida aqui de propósito: se alguém tirar
  # um campo de lá, o teste de contrato mais abaixo é que acusa — não este.
  @metadata_prod [
    :request_id,
    :trace_id,
    :clinic_id,
    :actor_id,
    :method,
    :route,
    :status,
    :duration_ms,
    :client_ip
  ]

  # 2026-05-28T20:26:40Z em microssegundos, que é a unidade do `:logger`.
  @instante 1_780_000_000_000_000

  defp formatar(msg, meta, nivel, opts) do
    {modulo, config} = Api.LogFormatter.new(opts)

    %{level: nivel, meta: Map.put_new(meta, :time, @instante), msg: msg}
    |> modulo.format(config)
    |> IO.iodata_to_binary()
  end

  defp linha(msg, meta \\ %{}, nivel \\ :info, opts \\ [metadata: @metadata_prod]) do
    msg |> formatar(meta, nivel, opts) |> Jason.decode!()
  end

  describe "a linha de requisição" do
    setup do
      # Exatamente o que `ApiWeb.RequestLogger.registrar/2` entrega ao `Logger`.
      meta = %{
        method: "POST",
        route: "/api/patients/:id",
        status: 422,
        duration_ms: 12.3,
        client_ip: "203.0.113.7",
        clinic_id: "019f7c5b-1bee-7a32-9fad-c3d6f0a83177",
        actor_id: "019f7c5b-1bee-7a32-9fad-000000000001",
        request_id: "F9x1abc",
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736"
      }

      %{linha: linha({:string, "requisição"}, meta)}
    end

    test "põe os campos do request e da response na RAIZ do JSON", %{linha: linha} do
      # O request.
      assert linha["method"] == "POST"
      assert linha["route"] == "/api/patients/:id"
      assert linha["client_ip"] == "203.0.113.7"

      # A response.
      assert linha["status"] == 422
      assert linha["duration_ms"] == 12.3
    end

    test "não aninha nada sob `metadata` — foi isso que apagou os painéis", %{linha: linha} do
      refute Map.has_key?(linha, "metadata")
    end

    test "mantém `severity` e `time` no topo", %{linha: linha} do
      # O rótulo `level` do Loki sai de `severity` (`alloy.alloy`, estágio 4). Renomear esta chave
      # apaga o rótulo em silêncio, que é o defeito que o próprio comentário de lá conta ter
      # cometido uma vez.
      assert linha["severity"] == "info"
      assert linha["time"] == "2026-05-28T20:26:40.000Z"
    end

    test "mantém a mensagem em `message`", %{linha: linha} do
      assert linha["message"] == "requisição"
    end

    test "carrega a correlação — `request_id`, `trace_id` e o escopo do tenant", %{linha: linha} do
      assert linha["request_id"] == "F9x1abc"
      assert linha["trace_id"] == "4bf92f3577b34da6a3ce929d0e0e4736"
      assert linha["clinic_id"] == "019f7c5b-1bee-7a32-9fad-c3d6f0a83177"
      assert linha["actor_id"] == "019f7c5b-1bee-7a32-9fad-000000000001"
    end

    test "5xx sai como `error`, que é o filtro de uma investigação" do
      linha = linha({:string, "requisição"}, %{status: 500, route: "/api/agenda"}, :error)

      assert linha["severity"] == "error"
      assert linha["status"] == 500
    end
  end

  describe "o evento estruturado do Oban" do
    setup do
      # `Oban.Telemetry.attach_default_logger(encode: false)` (`Api.Application`) entrega um MAPA
      # ao Logger, não um texto. Com o formatter antigo ele ia parar sob `message`, e o rótulo no
      # Loki virava `message_worker` — os painéis de job do 03 e do 09 pediam `worker`.
      msg =
        {:report,
         %{
           source: "oban",
           event: "job:stop",
           worker: "Api.Messaging.ReminderJob",
           queue: "default",
           state: "success",
           duration: 41_233
         }}

      %{linha: linha(msg)}
    end

    test "achata os campos do evento na raiz", %{linha: linha} do
      assert linha["worker"] == "Api.Messaging.ReminderJob"
      assert linha["queue"] == "default"
      assert linha["state"] == "success"
      assert linha["source"] == "oban"
    end

    test "usa o `event` como mensagem legível", %{linha: linha} do
      # Sem isto a coluna "message" do painel de log fica vazia para toda linha de job — e um
      # campo do contrato que existe em metade das linhas é pior que um campo que não existe.
      assert linha["message"] == "job:stop"
    end
  end

  describe "as bordas" do
    test "campo do evento não sobrescreve `severity` nem `time`" do
      msg = {:report, %{severity: "debug", time: "ontem", event: "suspeito"}}

      linha = linha(msg, %{}, :error)

      assert linha["severity"] == "error"
      assert linha["time"] == "2026-05-28T20:26:40.000Z"
    end

    test "metadata fora da lista não entra na linha" do
      linha = linha({:string, "oi"}, %{route: "/api/x", segredo: "não deveria sair"})

      assert linha["route"] == "/api/x"
      refute Map.has_key?(linha, "segredo")
    end

    test "a `conn` nunca vai para a linha, nem com `metadata: :all`" do
      # A `conn` inteira no log seria a linha com cabeçalhos, cookies e corpo — e `:all` é um pé
      # na porta que alguém pode dar em dev sem perceber o que arrasta junto.
      linha =
        linha({:string, "oi"}, %{conn: %Plug.Conn{}, route: "/api/x"}, :info, metadata: :all)

      assert linha["route"] == "/api/x"
      refute Map.has_key?(linha, "conn")
    end

    test "a linha termina em quebra e é um JSON por linha" do
      texto = formatar({:string, "requisição"}, %{status: 200}, :info, metadata: @metadata_prod)

      assert String.ends_with?(texto, "\n")
      assert texto |> String.trim_trailing() |> String.contains?("\n") == false
    end

    test "crash report vira texto em `message`, sem estourar a linha" do
      meta = %{crash_reason: {%RuntimeError{message: "boom"}, []}, route: "/api/x"}

      linha = linha({:string, "erro fatal"}, meta, :error)

      assert linha["message"] == "erro fatal"
      assert linha["route"] == "/api/x"
    end
  end

  describe "o contrato com produção" do
    test "`config/prod.exs` usa este formatter e mantém os campos que os painéis consultam" do
      # O formatter certo com a configuração errada dá o MESMO painel vazio. Ler o arquivo de
      # produção é o que fecha essa brecha — e é barato: ele não depende de env var nenhuma.
      config = Config.Reader.read!("config/prod.exs", env: :prod)

      {formatter, opts} = get_in(config, [:logger, :default_handler])[:formatter]

      assert formatter == Api.LogFormatter

      # Cada um destes é consultado por pelo menos um painel dos dashboards 01, 02, 04 e 05.
      for campo <- [:route, :status, :duration_ms, :clinic_id, :actor_id, :method] do
        assert campo in opts[:metadata],
               "`#{campo}` saiu da lista de prod — algum painel do Grafana vai abrir vazio"
      end

      # ADR-025: sem estas três, o `RequestLogger` produz payload/query/response e o formatter os
      # descarta caladamente — a investigação de um 422 volta a não ter o que ler.
      for campo <- [:payload, :query, :response] do
        assert campo in opts[:metadata], "`#{campo}` saiu da lista de prod — o ADR-025 fica morto"
      end
    end

    test "a redação está ligada em produção" do
      # O formatter certo, os campos certos e **nenhum redactor** seria a pior das combinações:
      # payload de paciente indo para o Loki em claro, com todo o resto parecendo em ordem.
      config = Config.Reader.read!("config/prod.exs", env: :prod)
      {_formatter, opts} = get_in(config, [:logger, :default_handler])[:formatter]

      assert {Api.LogRedacao, _} = List.first(opts[:redactors])
    end
  end
end
