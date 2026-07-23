defmodule Api.Waitlist.SlotFinderTest do
  @moduledoc """
  A tabela-verdade do motor de vagas (doc 25 §1, RN-37..42) — o port de `filaVagas`. Motor
  **puro**: cada teste monta a entrada à mão (profissional, expediente, agendamentos, relógio) e
  confere a saída, sem tocar no banco. É o teste de fogo do port não-mecânico.
  """
  use ExUnit.Case, async: true

  alias Api.Waitlist.SlotFinder

  @prof %{id: "p1", segue_horario_clinica: true}
  # 2026-07-20 é segunda (dow 1); 22 é quarta (dow 3); 24 é sexta (dow 5).
  @segunda ~D[2026-07-20]

  defp sources(hours_by_dow) do
    %{
      @prof.id => %{
        clinic_hours:
          Enum.map(hours_by_dow, fn {dow, periods} -> %{dow: dow, periods: periods} end),
        professional_hours: [],
        clinic_exceptions: [],
        professional_exceptions: []
      }
    }
  end

  defp all_days(periods), do: Map.new(0..6, &{&1, periods})

  defp base(over \\ %{}) do
    %{
      entry: Map.merge(%{janela: :qualquer, rules: []}, Map.get(over, :entry, %{})),
      professionals: Map.get(over, :professionals, [@prof]),
      sources_by_prof: sources(Map.get(over, :hours, all_days([["08:00", "12:00"]]))),
      appts_by_prof_day: Map.get(over, :appts, %{}),
      today: Map.get(over, :today, @segunda),
      now_minutes: Map.get(over, :now_minutes, 0)
    }
  end

  defp find(over), do: SlotFinder.find_slots(base(over))

  defp on(slots, date), do: Enum.filter(slots, &(&1.date == date))
  defp starts(slots), do: Enum.map(slots, & &1.start)

  describe "disponibilidade geral (passada 2)" do
    test "emite a primeira brecha de cada período do dia" do
      today = find(%{hours: all_days([["08:00", "12:00"], ["13:00", "18:00"]])}) |> on(@segunda)

      assert starts(today) == [480, 780]
      assert Enum.all?(today, &(&1.freed == false and &1.rule_index == nil))
    end

    test "um agendamento ocupado empurra a brecha para depois dele" do
      appts = %{{@prof.id, @segunda} => [%{start: 480, end: 530, freed: false}]}
      today = find(%{appts: appts}) |> on(@segunda)

      # 08:00 está ocupado; a primeira brecha livre é 08:40.
      assert starts(today) == [540]
    end
  end

  describe "vagas que abriram (passada 1)" do
    test "cancelamento/falta vira vaga no horário exato e vem primeiro" do
      appts = %{{@prof.id, @segunda} => [%{start: 540, end: 590, freed: true}]}
      today = find(%{appts: appts}) |> on(@segunda)

      assert [freed, geral] = today
      assert freed.start == 540 and freed.freed == true
      assert geral.start == 480 and geral.freed == false
    end

    test "dedup: a vaga que abriu vence a geral no mesmo horário" do
      appts = %{{@prof.id, @segunda} => [%{start: 480, end: 530, freed: true}]}
      today = find(%{appts: appts}) |> on(@segunda)

      assert [%{start: 480, freed: true}] = today
    end
  end

  describe "corte do passado (relógio, RN-41)" do
    test "no dia de hoje, brechas antes de agora são descartadas" do
      # agora = 10:00 (600 min); a primeira brecha >= agora é 10:00.
      today = find(%{now_minutes: 600}) |> on(@segunda)
      assert starts(today) == [600]
    end

    test "o corte não vale para os dias seguintes" do
      amanha = find(%{now_minutes: 600}) |> on(~D[2026-07-21])
      assert starts(amanha) == [480]
    end
  end

  describe "janela (RN-39)" do
    test ":manha rejeita horários >= 12:00" do
      today =
        find(%{
          entry: %{janela: :manha},
          hours: all_days([["08:00", "12:00"], ["13:00", "18:00"]])
        })
        |> on(@segunda)

      assert starts(today) == [480]
    end

    test ":tarde rejeita horários < 12:00" do
      today =
        find(%{
          entry: %{janela: :tarde},
          hours: all_days([["08:00", "12:00"], ["13:00", "18:00"]])
        })
        |> on(@segunda)

      assert starts(today) == [780]
    end
  end

  describe "regras de disponibilidade" do
    test "regra :semana só casa nos dias-da-semana dados, com o índice da regra" do
      rules = [%{tipo: :semana, dows: [3], data: nil, periodos: [["08:00", "12:00"]]}]

      slots = find(%{entry: %{rules: rules}})

      assert on(slots, @segunda) == []
      # 2026-07-22 é quarta (dow 3).
      assert [%{start: 480, rule_index: 0}] = on(slots, ~D[2026-07-22])
    end

    test "regra :data só casa na data dada" do
      rules = [%{tipo: :data, dows: [], data: ~D[2026-07-24], periodos: [["08:00", "12:00"]]}]

      slots = find(%{entry: %{rules: rules}})

      assert on(slots, @segunda) == []
      assert [%{start: 480, rule_index: 0}] = on(slots, ~D[2026-07-24])
    end

    test "regra :data no passado expira e é ignorada (vira 'sem regra' → passa livre)" do
      rules = [%{tipo: :data, dows: [], data: ~D[2026-07-10], periodos: [["08:00", "12:00"]]}]

      today = find(%{entry: %{rules: rules}}) |> on(@segunda)

      assert [%{start: 480, rule_index: nil}] = today
    end

    test "faixa da regra é respeitada (vaga fora da faixa não casa)" do
      # Regra manda 09:00–11:00; a brecha das 08:00 não casa, a das 09:00 sim.
      rules = [%{tipo: :semana, dows: [1], data: nil, periodos: [["09:00", "11:00"]]}]
      appts = %{{@prof.id, @segunda} => [%{start: 480, end: 530, freed: false}]}

      today = find(%{entry: %{rules: rules}, appts: appts}) |> on(@segunda)

      # 08:00 ocupado; 08:40 fora da faixa; 09:00 dentro → primeira que casa é 540.
      assert [%{start: 540, rule_index: 0}] = today
    end
  end

  describe "expediente" do
    test "dia fechado (sem período) é pulado" do
      # Aberto só às segundas; nos outros dias o motor pula.
      hours = %{1 => [["08:00", "12:00"]]}
      slots = find(%{hours: hours})

      assert on(slots, @segunda) |> starts() == [480]
      # Terça (2026-07-21) fechada.
      assert on(slots, ~D[2026-07-21]) == []
    end
  end

  describe "profissionais preferidos" do
    test "varre só os profissionais passados" do
      p2 = %{id: "p2", segue_horario_clinica: true}

      input =
        base()
        |> Map.put(:professionals, [@prof, p2])
        |> put_in(
          [:sources_by_prof, p2.id],
          hd(Map.values(sources(all_days([["08:00", "12:00"]]))))
        )

      profs = SlotFinder.find_slots(input) |> on(@segunda) |> Enum.map(& &1.professional_id)
      assert Enum.sort(profs) == ["p1", "p2"]
    end
  end
end
