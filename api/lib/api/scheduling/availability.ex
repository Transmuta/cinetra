defmodule Api.Scheduling.Availability do
  @moduledoc """
  O motor de disponibilidade (doc 25 §4) — **puro**, no molde de `Api.Scheduling.Periods`:
  recebe os dados já carregados e responde se o profissional atende naquela data e em quais
  períodos. Nada de banco, nada de escopo.

  ## A precedência de 4 camadas — a primeira decide (RN-07..10)

    * **(A)** exceção da clínica `tipo != :horario` → fechado para todos (D14, bloqueio
      absoluto: nem admin agenda em feriado);
    * **(B)** exceção do profissional na data;
    * **(C)** exceção da clínica `:horario` (expediente especial do dia);
    * **(D)** grade semanal — `:herda` cai no `ClinicHours`, `:custom` usa os próprios
      períodos, `:fechado` não atende; **linha ausente** cai em
      `Professional.segue_horario_clinica`.

  Duas assimetrias **load-bearing**, e é por isso que a ordem não é negociável:

    1. **feriado vence o pontual do profissional** (A antes de B) — a clínica fechada fecha
       para todos, mesmo quem tinha horário especial marcado;
    2. **folga do profissional vence o horário especial da clínica** (B antes de C) — quem
       está de folga não é convocado porque a clínica resolveu abrir em horário diferente.

  E `:fechado` **≠** linha ausente (RN-10): a primeira é decisão explícita de não atender, a
  segunda é omissão que cai no default do profissional. Elas devolvem motivos distintos de
  propósito — a UI precisa dizer *"folga"* e não *"sem grade"*.

  ## Onde isto muda o sistema

  Hoje a composição das camadas é feita **no cliente**, por `resolveWeekday` em
  `web/src/lib/professionals.ts`. Com o motor aqui, aquele arquivo deixa de ser autoridade e
  vira formatação — o veredito é sempre do servidor (09 §8).
  """

  alias Api.Scheduling.Periods

  @typedoc "Períodos abertos, ou o motivo do fechamento — sempre um átomo estável para a UI."
  @type result :: {:open, [[String.t()]]} | {:closed, atom()}

  @typedoc """
  As quatro fontes já carregadas. Listas cruas (não indexadas): quem chama passa o que leu do
  banco, e a indexação por data/dow é problema deste módulo.
  """
  @type sources :: %{
          clinic_hours: [%{dow: integer(), periods: list()}],
          professional_hours: [%{dow: integer(), modo: atom(), periods: list()}],
          clinic_exceptions: [%{data: Date.t(), tipo: atom(), periods: list()}],
          professional_exceptions: [%{data: Date.t(), tipo: atom(), periods: list()}]
        }

  @doc """
  Resolve os períodos em que `professional` atende em `date`, aplicando a precedência acima.

  `professional` precisa de `:segue_horario_clinica` (o fallback da camada D). As exceções em
  `sources` já devem vir filtradas pelo profissional em questão — este módulo não conhece
  `professional_id`, só recebe as listas que lhe dizem respeito.
  """
  @spec day_periods(Date.t(), map(), sources()) :: result()
  def day_periods(%Date{} = date, professional, sources) do
    # A ordem das cláusulas É a regra. Não reordenar sem reler as duas assimetrias acima.
    with nil <- layer_a(date, sources),
         nil <- layer_b(date, sources),
         nil <- layer_c(date, sources) do
      layer_d(date, professional, sources)
    end
  end

  # (A) Clínica fechada por exceção: bloqueio absoluto, vence tudo.
  defp layer_a(date, sources) do
    case on_date(sources[:clinic_exceptions], date) do
      %{tipo: tipo} when tipo != :horario -> {:closed, :clinica_fechada_excecao}
      _ -> nil
    end
  end

  # (B) Exceção do profissional: folga fecha, horário pontual sobrepõe.
  defp layer_b(date, sources) do
    case on_date(sources[:professional_exceptions], date) do
      %{tipo: :horario, periods: periods} -> open_or_closed(periods, :folga_profissional)
      %{tipo: _} -> {:closed, :folga_profissional}
      nil -> nil
    end
  end

  # (C) Horário especial da clínica no dia.
  defp layer_c(date, sources) do
    case on_date(sources[:clinic_exceptions], date) do
      %{tipo: :horario, periods: periods} -> open_or_closed(periods, :clinica_fechada)
      _ -> nil
    end
  end

  # (D) Grade semanal. Linha ausente cai no default do profissional (RN-10).
  defp layer_d(date, professional, sources) do
    dow = dow(date)

    case Enum.find(sources[:professional_hours] || [], &(&1.dow == dow)) do
      %{modo: :custom, periods: periods} -> open_or_closed(periods, :folga_semanal)
      %{modo: :fechado} -> {:closed, :folga_semanal}
      %{modo: :herda} -> clinic_day(dow, sources)
      nil -> fallback(dow, professional, sources)
    end
  end

  defp fallback(dow, professional, sources) do
    if Map.get(professional, :segue_horario_clinica, true),
      do: clinic_day(dow, sources),
      else: {:closed, :sem_grade}
  end

  defp clinic_day(dow, sources) do
    case Enum.find(sources[:clinic_hours] || [], &(&1.dow == dow)) do
      %{periods: periods} -> open_or_closed(periods, :clinica_fechada)
      nil -> {:closed, :clinica_fechada}
    end
  end

  # Lista vazia de períodos é "fechado", não "aberto sem horário" — o motivo vem de quem chama,
  # porque a mesma lista vazia significa coisas diferentes em cada camada.
  defp open_or_closed([], reason), do: {:closed, reason}
  defp open_or_closed(periods, _reason), do: {:open, periods}

  defp on_date(nil, _date), do: nil
  defp on_date(exceptions, date), do: Enum.find(exceptions, &(&1.data == date))

  # `Date.day_of_week/1` devolve 1=segunda..7=domingo; o projeto usa 0=domingo..6=sábado
  # (`ClinicHours.dow`, constraint 0..6), que é o `getDay()` do JS do protótipo.
  defp dow(date), do: rem(Date.day_of_week(date), 7)

  @doc """
  O intervalo `{início, fim}` (minutos desde a meia-noite) cabe **inteiro em UM** dos períodos?

  Somar períodos não vale: 11:30–12:20 num dia `[["08:00","12:00"], ["13:00","18:00"]]` é
  recusado, porque atravessa o almoço. É a regra do §7 e o que separa "a clínica está aberta
  nesse intervalo" de "a sessão cabe".
  """
  @spec fits?([[String.t()]], {integer(), integer()}) :: boolean()
  def fits?(periods, {ini, fim}) when is_list(periods) do
    Enum.any?(periods, fn [pini, pfim] ->
      Periods.to_minutes(pini) <= ini and fim <= Periods.to_minutes(pfim)
    end)
  end
end
