defmodule Api.Scheduling.AvailabilityTest do
  @moduledoc """
  Tabela-verdade da precedência de 4 camadas (doc 25 §4, RN-07..10; `02:113` / `07:2.1`).

  Módulo **puro**: nada de banco, nada de escopo. É o que permite testar as 15 combinações
  como test table em vez de montar 15 clínicas.
  """
  use ExUnit.Case, async: true

  alias Api.Scheduling.Availability

  # Uma segunda-feira (dow 1) e uma terça (dow 2), para separar dia-com-exceção de dia-sem.
  @segunda ~D[2026-07-20]
  @terca ~D[2026-07-21]

  # Profissional que herda por padrão quando não há linha na grade.
  defp prof(opts \\ []) do
    %{
      id: "p1",
      segue_horario_clinica: Keyword.get(opts, :segue, true)
    }
  end

  defp sources(opts \\ []) do
    %{
      clinic_hours: Keyword.get(opts, :clinic_hours, [%{dow: 1, periods: [["08:00", "18:00"]]}]),
      professional_hours: Keyword.get(opts, :professional_hours, []),
      clinic_exceptions: Keyword.get(opts, :clinic_exceptions, []),
      professional_exceptions: Keyword.get(opts, :professional_exceptions, [])
    }
  end

  describe "camada D — grade semanal" do
    test "linha ausente + segue_horario_clinica: true → herda o expediente da clínica" do
      assert {:open, [["08:00", "18:00"]]} =
               Availability.day_periods(@segunda, prof(), sources())
    end

    test "linha ausente + segue_horario_clinica: false → fechado (RN-10)" do
      assert {:closed, :sem_grade} =
               Availability.day_periods(@segunda, prof(segue: false), sources())
    end

    test "modo :herda → expediente da clínica" do
      src = sources(professional_hours: [%{dow: 1, modo: :herda, periods: []}])
      assert {:open, [["08:00", "18:00"]]} = Availability.day_periods(@segunda, prof(), src)
    end

    test "modo :custom → os próprios períodos" do
      src = sources(professional_hours: [%{dow: 1, modo: :custom, periods: [["09:00", "12:00"]]}])
      assert {:open, [["09:00", "12:00"]]} = Availability.day_periods(@segunda, prof(), src)
    end

    test "modo :fechado → fechado, e é DIFERENTE de linha ausente (RN-10)" do
      src = sources(professional_hours: [%{dow: 1, modo: :fechado, periods: []}])
      assert {:closed, :folga_semanal} = Availability.day_periods(@segunda, prof(), src)

      # Mesma pergunta, sem a linha: cai no fallback do profissional, e o motivo é outro.
      assert {:open, _} = Availability.day_periods(@segunda, prof(), sources())
    end

    test "clínica fechada no dia (periods vazio) → fechado" do
      src = sources(clinic_hours: [%{dow: 1, periods: []}])
      assert {:closed, :clinica_fechada} = Availability.day_periods(@segunda, prof(), src)
    end

    test "dia sem linha nenhuma na clínica → fechado" do
      assert {:closed, :clinica_fechada} = Availability.day_periods(@terca, prof(), sources())
    end
  end

  describe "camada C — exceção de horário da clínica" do
    test ":horario da clínica sobrepõe a grade semanal" do
      src =
        sources(
          clinic_exceptions: [%{data: @segunda, tipo: :horario, periods: [["10:00", "14:00"]]}]
        )

      assert {:open, [["10:00", "14:00"]]} = Availability.day_periods(@segunda, prof(), src)
    end

    test "exceção em OUTRA data não afeta o dia consultado" do
      src =
        sources(
          clinic_exceptions: [%{data: @terca, tipo: :horario, periods: [["10:00", "14:00"]]}]
        )

      assert {:open, [["08:00", "18:00"]]} = Availability.day_periods(@segunda, prof(), src)
    end

    test "C vence a camada D mesmo quando o profissional tem :custom" do
      src =
        sources(
          professional_hours: [%{dow: 1, modo: :custom, periods: [["09:00", "12:00"]]}],
          clinic_exceptions: [%{data: @segunda, tipo: :horario, periods: [["10:00", "14:00"]]}]
        )

      assert {:open, [["10:00", "14:00"]]} = Availability.day_periods(@segunda, prof(), src)
    end
  end

  describe "camada B — exceção do profissional" do
    test "folga do profissional (:fechado) → fechado" do
      src = sources(professional_exceptions: [%{data: @segunda, tipo: :fechado, periods: []}])
      assert {:closed, :folga_profissional} = Availability.day_periods(@segunda, prof(), src)
    end

    test ":horario pontual do profissional sobrepõe a grade" do
      src =
        sources(
          professional_exceptions: [
            %{data: @segunda, tipo: :horario, periods: [["15:00", "17:00"]]}
          ]
        )

      assert {:open, [["15:00", "17:00"]]} = Availability.day_periods(@segunda, prof(), src)
    end

    test "ASSIMETRIA 1: folga do profissional vence o horário especial da clínica (B antes de C)" do
      src =
        sources(
          clinic_exceptions: [%{data: @segunda, tipo: :horario, periods: [["10:00", "14:00"]]}],
          professional_exceptions: [%{data: @segunda, tipo: :fechado, periods: []}]
        )

      assert {:closed, :folga_profissional} = Availability.day_periods(@segunda, prof(), src)
    end
  end

  describe "camada A — fechamento da clínica (bloqueio absoluto, D14)" do
    test "feriado da clínica fecha para todos" do
      src = sources(clinic_exceptions: [%{data: @segunda, tipo: :fechado, periods: []}])
      assert {:closed, :clinica_fechada_excecao} = Availability.day_periods(@segunda, prof(), src)
    end

    test "ASSIMETRIA 2: feriado vence o horário pontual do profissional (A antes de B)" do
      src =
        sources(
          clinic_exceptions: [%{data: @segunda, tipo: :fechado, periods: []}],
          professional_exceptions: [
            %{data: @segunda, tipo: :horario, periods: [["15:00", "17:00"]]}
          ]
        )

      assert {:closed, :clinica_fechada_excecao} = Availability.day_periods(@segunda, prof(), src)
    end
  end

  describe "fits?/2 — cabe INTEIRO em UM período" do
    test "cabe dentro de um período" do
      assert Availability.fits?([["08:00", "12:00"]], {480, 530})
    end

    test "encostar nas bordas cabe" do
      assert Availability.fits?([["08:00", "12:00"]], {480, 720})
    end

    test "atravessar o almoço NÃO cabe, mesmo somando os dois períodos" do
      periods = [["08:00", "12:00"], ["13:00", "18:00"]]
      refute Availability.fits?(periods, {690, 740})
    end

    test "fora de qualquer período não cabe" do
      refute Availability.fits?([["08:00", "12:00"]], {800, 840})
    end

    test "dia fechado não cabe nada" do
      refute Availability.fits?([], {480, 530})
    end
  end
end
