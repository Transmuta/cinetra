defmodule Api.Scheduling.LocalTimeTest do
  @moduledoc """
  A ponte `"HH:MM"` local ↔ `:utc_datetime` (doc 25 §4).

  Os testes de DST usam **`America/Santiago`**, não `America/Sao_Paulo`: o Brasil não tem
  horário de verão desde 2019, então com o fuso de casa os ramos `:gap`/`:ambiguous` nunca
  são exercitados e a regra ficaria sem cobertura real (doc 25 §10). As datas abaixo foram
  conferidas contra a base `tz` instalada, não deduzidas.
  """
  use ExUnit.Case, async: true

  alias Api.Scheduling.LocalTime

  @sp "America/Sao_Paulo"
  @scl "America/Santiago"

  describe "to_utc/3" do
    test "converte hora local para UTC (São Paulo, UTC-3)" do
      assert {:ok, dt} = LocalTime.to_utc(~D[2026-07-20], "08:00", @sp)
      assert dt == ~U[2026-07-20 11:00:00Z]
    end

    test "rejeita horário malformado" do
      assert {:error, :invalid_time} = LocalTime.to_utc(~D[2026-07-20], "25:00", @sp)
      assert {:error, :invalid_time} = LocalTime.to_utc(~D[2026-07-20], "8:00", @sp)
    end

    test "rejeita fuso desconhecido" do
      assert {:error, :invalid_timezone} =
               LocalTime.to_utc(~D[2026-07-20], "08:00", "Marte/Olympus")
    end

    test "GAP (salto de DST): empurra para depois do salto" do
      # Em 2026-09-06 o Chile pula 00:00→01:00; 00:30 local não existe.
      assert {:ok, dt} = LocalTime.to_utc(~D[2026-09-06], "00:30", @scl)
      assert dt == ~U[2026-09-06 04:00:00Z]
    end

    test "AMBÍGUO (volta de DST): fica com a primeira ocorrência" do
      # Em 2026-04-04 o Chile repete a hora 23:00–24:00; 23:30 acontece duas vezes.
      assert {:ok, dt} = LocalTime.to_utc(~D[2026-04-04], "23:30", @scl)
      # A primeira ocorrência ainda está em -03 (verão), logo 02:30Z; a segunda seria 03:30Z.
      assert dt == ~U[2026-04-05 02:30:00Z]
    end
  end

  describe "to_local_minutes/2" do
    test "devolve minutos desde a meia-noite no fuso da clínica" do
      assert LocalTime.to_local_minutes(~U[2026-07-20 11:00:00Z], @sp) == 480
    end

    test "não é o minuto do UTC — o fuso importa" do
      refute LocalTime.to_local_minutes(~U[2026-07-20 11:00:00Z], @sp) == 660
    end
  end

  describe "to_local_date/2" do
    test "a data local pode diferir da data UTC perto da meia-noite" do
      # 02:00Z de dia 21 ainda é dia 20 às 23:00 em São Paulo.
      assert LocalTime.to_local_date(~U[2026-07-21 02:00:00Z], @sp) == ~D[2026-07-20]
    end
  end

  describe "ida e volta" do
    test "to_utc |> to_local_minutes recupera o minuto original" do
      for hhmm <- ["00:00", "08:15", "12:30", "23:45"] do
        {:ok, dt} = LocalTime.to_utc(~D[2026-07-20], hhmm, @sp)
        assert LocalTime.to_local_minutes(dt, @sp) == Api.Scheduling.Periods.to_minutes(hhmm)
      end
    end
  end
end
