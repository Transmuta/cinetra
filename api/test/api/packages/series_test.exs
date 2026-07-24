defmodule Api.Packages.SeriesTest do
  @moduledoc """
  O motor de série (RN-18…RN-21, doc 02 §1.5) — `computeSerie` do protótipo
  ([`:1081`](../../../../interface/Movimento.dc.html#L1081)) como domínio puro.

  Sem banco, sem escopo, sem relógio: tudo entra por argumento. É o que torna as regras de
  calendário testáveis sozinhas, que é o motivo de o motor existir separado (doc 04 §2).
  """
  use ExUnit.Case, async: true

  alias Api.Packages.Series

  doctest Api.Packages.Series

  # 2026-07-20 é uma segunda-feira. Seg=1, Qua=3 no `Date.day_of_week/2` com `:sunday` como 0 —
  # a mesma convenção do `dow` do protótipo (`getDay()`) e do `ClinicHours.dow`.
  @segunda ~D[2026-07-20]

  defp grade(opts \\ []) do
    %{
      dows: Keyword.get(opts, :dows, [1, 3]),
      horarios: Keyword.get(opts, :horarios, %{1 => "08:00", 3 => "09:00"})
    }
  end

  describe "RN-18 — a série materializa N ocorrências úteis" do
    test "quatro sessões em seg/qua saem alternando, com o horário de cada dia" do
      assert {:ok, ocorrencias} = Series.project(@segunda, grade(), 4, MapSet.new())

      assert [
               %{data: ~D[2026-07-20], hhmm: "08:00", feriado?: false},
               %{data: ~D[2026-07-22], hhmm: "09:00", feriado?: false},
               %{data: ~D[2026-07-27], hhmm: "08:00", feriado?: false},
               %{data: ~D[2026-07-29], hhmm: "09:00", feriado?: false}
             ] = ocorrencias
    end

    test "âncora fora da grade começa na próxima ocorrência" do
      # 2026-07-21 é terça; a grade é seg/qua.
      assert {:ok, [primeira | _]} = Series.project(~D[2026-07-21], grade(), 2, MapSet.new())
      assert primeira.data == ~D[2026-07-22]
    end

    test "uma sessão por semana também funciona" do
      grade = grade(dows: [5], horarios: %{5 => "14:00"})
      assert {:ok, ocorrencias} = Series.project(@segunda, grade, 3, MapSet.new())

      assert Enum.map(ocorrencias, & &1.data) ==
               [~D[2026-07-24], ~D[2026-07-31], ~D[2026-08-07]]
    end
  end

  describe "RN-19/RN-20 — feriado pula e ESTENDE" do
    test "o feriado sai na lista marcado, não conta, e a série anda uma ocorrência a mais" do
      feriados = MapSet.new([~D[2026-07-22]])

      assert {:ok, ocorrencias} = Series.project(@segunda, grade(), 4, feriados)

      # cinco ocorrências para quatro sessões úteis
      assert length(ocorrencias) == 5
      assert Enum.count(ocorrencias, & &1.feriado?) == 1

      assert %{data: ~D[2026-07-22], feriado?: true} =
               Enum.find(ocorrencias, & &1.feriado?)

      # e a última útil foi empurrada para depois do que seria o fim
      assert List.last(ocorrencias).data == ~D[2026-08-03]
    end

    test "feriado fora dos dias da grade não muda nada" do
      # 2026-07-21 é terça — a grade nem passa por lá.
      feriados = MapSet.new([~D[2026-07-21]])

      assert {:ok, com} = Series.project(@segunda, grade(), 4, feriados)
      assert {:ok, sem} = Series.project(@segunda, grade(), 4, MapSet.new())
      assert com == sem
    end
  end

  describe "RN-21 — âncora inclusiva" do
    test "por padrão a série inclui o dia-âncora" do
      assert {:ok, [%{data: @segunda} | _]} = Series.project(@segunda, grade(), 2, MapSet.new())
    end

    test "`inclusive?: false` pula o dia-âncora" do
      assert {:ok, [primeira | _]} =
               Series.project(@segunda, grade(), 2, MapSet.new(), inclusive?: false)

      assert primeira.data == ~D[2026-07-22]
    end
  end

  describe "entradas que o protótipo aceitava em silêncio" do
    test "grade sem dias é erro, não laço infinito" do
      assert {:error, :dows_vazio} =
               Series.project(@segunda, %{dows: [], horarios: %{}}, 4, MapSet.new())
    end

    test "dia da grade sem horário é erro, não um '09:00' inventado" do
      grade = %{dows: [1, 3], horarios: %{1 => "08:00"}}
      assert {:error, {:horario_ausente, 3}} = Series.project(@segunda, grade, 4, MapSet.new())
    end

    test "dow inválido é recusado" do
      grade = %{dows: [7], horarios: %{7 => "08:00"}}
      assert {:error, {:dow_invalido, 7}} = Series.project(@segunda, grade, 1, MapSet.new())
    end

    test "total não-positivo é recusado" do
      assert {:error, :total_invalido} = Series.project(@segunda, grade(), 0, MapSet.new())
    end

    # A válvula `guard < 400` do protótipo devolvia uma série CURTA em silêncio. Aqui o mesmo
    # cenário é erro: melhor não materializar nada do que materializar metade de um pacote.
    test "feriado demais estoura o horizonte com erro, não devolve série curta" do
      feriados =
        Date.range(@segunda, Date.add(@segunda, 900))
        |> MapSet.new()

      assert {:error, :horizonte_excedido} = Series.project(@segunda, grade(), 4, feriados)
    end
  end
end
