defmodule Api.Scheduling.PeriodsTest do
  @moduledoc "Regras puras dos períodos (doc 22 §1) — sem banco."
  use ExUnit.Case, async: true

  alias Api.Scheduling.Periods

  describe "validate/1 — casos válidos" do
    test "dia fechado (lista vazia)" do
      assert :ok = Periods.validate([])
    end

    test "um período" do
      assert :ok = Periods.validate([["08:00", "12:00"]])
    end

    test "manhã e tarde, ordenados e sem sobreposição" do
      assert :ok = Periods.validate([["08:00", "12:00"], ["13:00", "18:00"]])
    end

    test "encostados (fim de um == início do outro) valem" do
      assert :ok = Periods.validate([["08:00", "12:00"], ["12:00", "18:00"]])
    end

    test "meia-noite às 23:59" do
      assert :ok = Periods.validate([["00:00", "23:59"]])
    end
  end

  describe "validate/1 — forma" do
    test "não é lista" do
      assert {:error, _} = Periods.validate("08:00-12:00")
    end

    test "período que não é par" do
      assert {:error, _} = Periods.validate([["08:00"]])
      assert {:error, _} = Periods.validate([["08:00", "12:00", "x"]])
    end

    test "horário malformado" do
      for bad <- [["8:00", "12:00"], ["08:60", "12:00"], ["24:00", "12:00"], ["0800", "12:00"]] do
        assert {:error, _} = Periods.validate([bad]), "#{inspect(bad)} deveria falhar"
      end
    end

    test "valores não-string no par" do
      assert {:error, _} = Periods.validate([["08:00", 1200]])
    end
  end

  describe "validate/1 — ordem e sobreposição" do
    test "início >= fim no mesmo período" do
      assert {:error, _} = Periods.validate([["12:00", "08:00"]])
      assert {:error, _} = Periods.validate([["12:00", "12:00"]])
    end

    test "períodos sobrepostos" do
      assert {:error, _} = Periods.validate([["08:00", "13:00"], ["12:00", "18:00"]])
    end

    test "períodos fora de ordem" do
      assert {:error, _} = Periods.validate([["13:00", "18:00"], ["08:00", "12:00"]])
    end
  end

  test "to_minutes/1" do
    assert Periods.to_minutes("00:00") == 0
    assert Periods.to_minutes("08:30") == 510
    assert Periods.to_minutes("23:59") == 1439
  end
end
