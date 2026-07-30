defmodule Api.CorrelacaoTest do
  @moduledoc """
  A segunda fronteira em que a correlação por `request_id` se perdia (doc 62 §12): entre a
  requisição que enfileira e o job que roda depois.
  """
  use ExUnit.Case, async: true

  alias Api.Correlacao

  setup do
    # O `Logger.metadata` é do processo e vaza entre testes do mesmo processo se não for limpo.
    Logger.metadata(request_id: nil)
    :ok
  end

  describe "opts/1" do
    test "carrega o request_id corrente para o meta do job" do
      Logger.metadata(request_id: "GMad2LyYYsqNyPEAAO3B")

      assert [meta: %{"request_id" => "GMad2LyYYsqNyPEAAO3B"}] = Correlacao.opts()
    end

    test "preserva as opções que o chamador já passava" do
      # O `SendJob` passa `scheduled_at` (a janela de silêncio do doc 52 §7). Perder isso trocaria
      # um lembrete adiado por um lembrete imediato — o pior estrago possível para uma mudança
      # que só queria carregar um id.
      Logger.metadata(request_id: "GMad2LyYYsqNyPEAAO3B")
      quando = ~U[2026-08-01 12:00:00Z]

      opts = Correlacao.opts(scheduled_at: quando)

      assert Keyword.fetch!(opts, :scheduled_at) == quando
      assert Keyword.fetch!(opts, :meta) == %{"request_id" => "GMad2LyYYsqNyPEAAO3B"}
    end

    test "não sobrescreve meta que o chamador já definiu" do
      Logger.metadata(request_id: "GMad2LyYYsqNyPEAAO3B")

      opts = Correlacao.opts(meta: %{"origem" => "cron"})

      assert Keyword.fetch!(opts, :meta) == %{
               "origem" => "cron",
               "request_id" => "GMad2LyYYsqNyPEAAO3B"
             }
    end

    test "fora de uma requisição não inventa meta" do
      # Job enfileirado por cron ou por outro job não tem `request_id`. Gravar `nil` ali criaria um
      # campo que parece correlação e não correlaciona nada — pior que a ausência, porque quem
      # consulta o log acreditaria nele.
      assert Correlacao.opts() == []

      assert Correlacao.opts(scheduled_at: ~U[2026-08-01 12:00:00Z]) == [
               scheduled_at: ~U[2026-08-01 12:00:00Z]
             ]
    end
  end
end
