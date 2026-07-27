defmodule Api.Scheduling.ImpactAnalysisTest do
  @moduledoc """
  O motor do **A3 / `futureConflicts`** (D12, RN-16) — puro, então testado sem banco.

  O que este arquivo protege, em ordem de importância:

    * **a definição de conflito**: cabia antes E deixa de caber depois. O encaixe que já estava
      fora do expediente **não** é conflito — sem isto, toda edição de horário abriria uma tela
      de "conflitos" listando encaixes antigos, e a lista deixaria de ser lida;
    * **as quatro portas** (semana da clínica, grade do profissional, exceção da clínica, exceção
      do profissional) produzem conflito pelo mesmo critério;
    * **a precedência da simulação é a do motor real** — o item que a RN-16 deixou aberto: um
      feriado novo da clínica conta o agendamento de quem tinha horário pontual naquele dia,
      porque fechamento da clínica é a camada (A) e vence a exceção do profissional.
  """
  use ExUnit.Case, async: true

  alias Api.Scheduling.ImpactAnalysis

  @tz "America/Sao_Paulo"
  # 2026-07-20 é uma segunda-feira (dow 1 na convenção do projeto: domingo = 0).
  @segunda ~D[2026-07-20]
  @terca ~D[2026-07-21]

  defp appt(opts \\ []) do
    date = Keyword.get(opts, :date, @segunda)
    hora = Keyword.get(opts, :hora, 9)
    duracao = Keyword.get(opts, :duracao, 50)

    # 09:00 local = 12:00Z (BRT = UTC-3, sem horário de verão em 2026).
    {:ok, starts_at} = DateTime.new(date, Time.new!(hora + 3, 0, 0), "Etc/UTC")

    %{
      id: Keyword.get(opts, :id, "a1"),
      date: date,
      starts_at: starts_at,
      ends_at: DateTime.add(starts_at, duracao * 60, :second),
      professional_id: Keyword.get(opts, :professional_id, "p1")
    }
  end

  defp prof(id \\ "p1"), do: %{id: id, segue_horario_clinica: true}

  defp sources(opts) do
    %{
      clinic_hours: Keyword.get(opts, :clinic_hours, [%{dow: 1, periods: [["08:00", "18:00"]]}]),
      professional_hours: Keyword.get(opts, :professional_hours, []),
      clinic_exceptions: Keyword.get(opts, :clinic_exceptions, []),
      professional_exceptions: Keyword.get(opts, :professional_exceptions, [])
    }
  end

  defp mapa(opts \\ []), do: %{"p1" => {prof(), sources(opts)}}

  describe "a definição de conflito" do
    test "cabia e deixa de caber: é conflito" do
      # 09:00–09:50 numa segunda 08–18. Encurtar para 08–09 tira o agendamento de dentro.
      assert [conflito] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 mapa(),
                 {:clinic_hours, %{1 => [["08:00", "09:00"]]}},
                 @tz
               )

      assert conflito.appointment_id == "a1"
      assert conflito.reason == :fora_do_expediente
      assert conflito.periods_depois == [["08:00", "09:00"]]
    end

    test "continua cabendo: não é conflito" do
      assert [] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 mapa(),
                 {:clinic_hours, %{1 => [["07:00", "12:00"]]}},
                 @tz
               )
    end

    test "o dia inteiro fecha: conflito com motivo de SEM ATENDIMENTO" do
      assert [conflito] =
               ImpactAnalysis.conflicts([appt()], mapa(), {:clinic_hours, %{1 => []}}, @tz)

      assert conflito.reason == :sem_atendimento
      assert conflito.periods_depois == []
    end

    # O ponto que separa uma tela útil de um inventário: o encaixe já estava fora antes.
    test "o que JÁ estava fora do expediente não vira conflito" do
      # 07:00 local, com a clínica abrindo 08:00 — um encaixe.
      encaixe = appt(hora: 7)

      assert [] =
               ImpactAnalysis.conflicts(
                 [encaixe],
                 mapa(),
                 {:clinic_hours, %{1 => [["08:00", "12:00"]]}},
                 @tz
               )
    end

    test "não atravessa o almoço: períodos somados não valem" do
      # 11:30–12:20 contra [08:00–12:00, 13:00–18:00]: cabia no bloco único de antes e não cabe
      # em nenhum dos dois de depois.
      atravessa = appt(hora: 11, duracao: 50)
      atravessa = %{atravessa | starts_at: DateTime.add(atravessa.starts_at, 30 * 60, :second)}
      atravessa = %{atravessa | ends_at: DateTime.add(atravessa.ends_at, 30 * 60, :second)}

      assert [_] =
               ImpactAnalysis.conflicts(
                 [atravessa],
                 mapa(),
                 {:clinic_hours, %{1 => [["08:00", "12:00"], ["13:00", "18:00"]]}},
                 @tz
               )
    end

    test "outro dia-da-semana não é afetado" do
      # A mudança é na TERÇA (dow 2); o agendamento é segunda.
      assert [] =
               ImpactAnalysis.conflicts([appt()], mapa(), {:clinic_hours, %{2 => []}}, @tz)
    end

    test "ordena por data e horário" do
      cedo = appt(id: "cedo", hora: 8)
      tarde = appt(id: "tarde", hora: 15)
      outro_dia = appt(id: "amanha", date: @terca, hora: 9)

      fontes = %{
        "p1" =>
          {prof(),
           sources(
             clinic_hours: [
               %{dow: 1, periods: [["08:00", "18:00"]]},
               %{dow: 2, periods: [["08:00", "18:00"]]}
             ]
           )}
      }

      conflitos =
        ImpactAnalysis.conflicts(
          [outro_dia, tarde, cedo],
          fontes,
          {:clinic_hours, %{1 => [], 2 => []}},
          @tz
        )

      assert Enum.map(conflitos, & &1.appointment_id) == ["cedo", "tarde", "amanha"]
    end
  end

  describe "grade do profissional" do
    test "fechar a segunda do profissional conflita a sessão dele" do
      assert [conflito] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 mapa(),
                 {:professional_hours, "p1", [%{dow: 1, modo: :fechado, periods: []}]},
                 @tz
               )

      assert conflito.reason == :sem_atendimento
    end

    test "a grade de OUTRO profissional não afeta este" do
      assert [] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 mapa(),
                 {:professional_hours, "p2", [%{dow: 1, modo: :fechado, periods: []}]},
                 @tz
               )
    end

    test "modo custom mais estreito que o da clínica conflita" do
      assert [conflito] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 mapa(),
                 {:professional_hours, "p1",
                  [%{dow: 1, modo: :custom, periods: [["08:00", "09:00"]]}]},
                 @tz
               )

      assert conflito.periods_depois == [["08:00", "09:00"]]
    end

    test "substitui a linha que já existia naquele dia, não soma" do
      fontes = %{
        "p1" =>
          {prof(),
           sources(professional_hours: [%{dow: 1, modo: :custom, periods: [["08:00", "18:00"]]}])}
      }

      assert [_] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 fontes,
                 {:professional_hours, "p1",
                  [%{dow: 1, modo: :custom, periods: [["08:00", "09:00"]]}]},
                 @tz
               )
    end
  end

  describe "exceções (feriado / folga)" do
    test "feriado da clínica na data conflita tudo daquele dia" do
      assert [conflito] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 mapa(),
                 {:clinic_exception, %{data: @segunda, tipo: :fechado, periods: []}},
                 @tz
               )

      assert conflito.reason == :sem_atendimento
    end

    test "exceção em OUTRA data não afeta" do
      assert [] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 mapa(),
                 {:clinic_exception, %{data: @terca, tipo: :fechado, periods: []}},
                 @tz
               )
    end

    test "horário especial da clínica que encurta o dia conflita" do
      assert [conflito] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 mapa(),
                 {:clinic_exception,
                  %{data: @segunda, tipo: :horario, periods: [["08:00", "09:00"]]}},
                 @tz
               )

      assert conflito.reason == :fora_do_expediente
    end

    test "folga do profissional na data conflita a sessão dele" do
      assert [_] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 mapa(),
                 {:professional_exception, "p1", %{data: @segunda, tipo: :fechado, periods: []}},
                 @tz
               )
    end

    # O item que a RN-16 deixou aberto (doc 12 §A.3). O protótipo dava prioridade à exceção
    # pré-existente do PROFISSIONAL sobre a exceção da clínica sendo simulada — inclusive quando
    # a nova era um FECHAMENTO. O motor real diz o contrário (camada A vence a B), e é ele que
    # decide o que vai acontecer depois de salvar.
    test "feriado novo da clínica vence o horário pontual que o profissional já tinha" do
      fontes = %{
        "p1" =>
          {prof(),
           sources(
             professional_exceptions: [
               %{data: @segunda, tipo: :horario, periods: [["08:00", "18:00"]]}
             ]
           )}
      }

      assert [conflito] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 fontes,
                 {:clinic_exception, %{data: @segunda, tipo: :fechado, periods: []}},
                 @tz
               )

      assert conflito.reason == :sem_atendimento
    end

    # A outra metade da mesma assimetria: horário ESPECIAL da clínica (camada C) perde para a
    # exceção do profissional (camada B). Aqui o protótipo e o motor concordam.
    test "horário especial da clínica NÃO vence a folga pontual do profissional" do
      fontes = %{
        "p1" =>
          {prof(),
           sources(
             professional_exceptions: [
               %{data: @segunda, tipo: :horario, periods: [["08:00", "18:00"]]}
             ]
           )}
      }

      assert [] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 fontes,
                 {:clinic_exception,
                  %{data: @segunda, tipo: :horario, periods: [["08:00", "08:30"]]}},
                 @tz
               )
    end

    test "aceita chaves em string (o rascunho vem da fronteira HTTP)" do
      assert [_] =
               ImpactAnalysis.conflicts(
                 [appt()],
                 mapa(),
                 {:clinic_exception, %{"data" => @segunda, "tipo" => "fechado", "periods" => []}},
                 @tz
               )
    end
  end

  test "profissional fora do mapa de fontes é omitido em vez de virar veredito inventado" do
    assert [] =
             ImpactAnalysis.conflicts(
               [appt(professional_id: "fantasma")],
               mapa(),
               {:clinic_hours, %{1 => []}},
               @tz
             )
  end
end
