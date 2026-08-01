defmodule Api.Tracing.OtlpFilterTest do
  @moduledoc """
  O filtro que troca o ruído do exportador OTLP por métrica (doc 96, O-2).

  Duas metades, e as duas precisam valer: a linha **some do log** e o contador **sobe**. Provar só
  a primeira seria trocar ruído por cegueira — que é exatamente o desenho que este filtro existe
  para não repetir.
  """
  use ExUnit.Case, async: true

  alias Api.Tracing.OtlpFilter

  # A forma real da linha, medida no container:
  #   [info] OTLP grpc export failed with error: {:shutdown, :nxdomain}
  defp linha_do_exportador(texto \\ "OTLP grpc export failed with error: {:shutdown, :nxdomain}") do
    %{
      level: :info,
      msg: {:string, texto},
      meta: %{mfa: {:otel_exporter_otlp, :export, 4}}
    }
  end

  describe "o que o filtro descarta" do
    test "a falha de export do OTLP não chega ao log" do
      assert :stop = OtlpFilter.filtrar(linha_do_exportador(), [])
    end

    test "vale para a forma REAL do `?LOG_INFO` do Erlang: {charlist, args}" do
      # É assim que `otel_exporter_otlp.erl:196` emite. Assumir `{:string, binário}` fazia o
      # filtro passar no teste e não filtrar nada em produção — foi o defeito da primeira versão.
      evento = %{
        level: :info,
        msg: {~c"OTLP grpc export failed with error: ~p", [{:shutdown, :nxdomain}]},
        meta: %{mfa: {:otel_exporter_otlp, :export, 4}}
      }

      assert :stop = OtlpFilter.filtrar(evento, [])
    end
  end

  describe "o que o filtro NÃO descarta" do
    test "outra mensagem do mesmo módulo passa" do
      # Recorte largo demais esconderia erro de configuração do SDK — que é justamente o que se
      # quer enxergar na largada.
      evento = linha_do_exportador("invalid OTLP endpoint configuration")

      assert ^evento = OtlpFilter.filtrar(evento, [])
    end

    test "mensagem parecida de OUTRO módulo passa" do
      evento = %{
        level: :error,
        msg: {:string, "export failed"},
        meta: %{mfa: {Api.Repo, :query, 3}}
      }

      assert ^evento = OtlpFilter.filtrar(evento, [])
    end

    test "evento sem `mfa` no metadata passa" do
      evento = %{level: :info, msg: {:string, "export failed"}, meta: %{}}

      assert ^evento = OtlpFilter.filtrar(evento, [])
    end
  end

  describe "o sinal que substitui a linha" do
    test "descartar a linha emite o evento que vira o contador do /metrics" do
      :telemetry.attach(
        "teste-otlp-#{System.unique_integer([:positive])}",
        OtlpFilter.evento(),
        fn evento, medidas, _meta, pid -> send(pid, {:telemetria, evento, medidas}) end,
        self()
      )

      assert :stop = OtlpFilter.filtrar(linha_do_exportador(), [])

      assert_receive {:telemetria, [:api, :otlp, :export_failure], %{count: 1}}
    end

    test "linha que passa NÃO conta como falha" do
      :telemetry.attach(
        "teste-otlp-neg-#{System.unique_integer([:positive])}",
        OtlpFilter.evento(),
        fn evento, medidas, _meta, pid -> send(pid, {:telemetria, evento, medidas}) end,
        self()
      )

      OtlpFilter.filtrar(linha_do_exportador("configuração inválida"), [])

      refute_receive {:telemetria, _, _}, 100
    end
  end
end
