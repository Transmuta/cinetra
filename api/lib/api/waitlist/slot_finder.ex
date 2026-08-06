defmodule Api.Waitlist.SlotFinder do
  @moduledoc """
  O motor de vagas da fila (doc 25 §1, RN-37..42) — **puro**, no molde de
  `Api.Scheduling.Availability`: recebe tudo já carregado (profissionais, fontes de expediente,
  agendamentos e o **relógio**) e responde as vagas compatíveis com um item da fila. Nada de
  banco, nada de escopo. É o port de `filaVagas`
  ([`:2531`](../../../interface/Movimento.dc.html#L2531)) + `fitsWin`
  ([`:2541`](../../../interface/Movimento.dc.html#L2541)), e por ser um port não-mecânico ganha
  arquivo e tabela-verdade próprios.

  ## O algoritmo, fiel ao protótipo

  Varre `DAYS=14` dias a partir de **hoje** × os profissionais preferidos (vazio ⇒ todos os
  ativos), pulando quem não atende no dia. Em cada dia, para cada profissional, **duas passadas
  de semânticas distintas** (RN-40):

    1. **vagas que abriram** (`freed: true`) — os agendamentos `cancelado`/`faltou` viram uma
       vaga no **horário exato** liberado, desde que caiba no expediente, esteja livre e passe
       janela+regras. É o que a UI destaca em teal com o selo "ABRIU";
    2. **disponibilidade geral** (`freed: false`) — caminha cada período de `STEP=30` em `STEP` e
       emite **só a primeira brecha livre** de cada período.

  Cortes: no dia de hoje, uma vaga com `start < agora` é descartada (RN-41 — o corte que só faz
  sentido com um relógio, ADR-009); dedup por `date|start|professional_id`, com a versão `freed`
  vencendo a geral colidente; teto de `CAP=50` (para o laço externo depois de um dia cheio). A
  saída ordena `freed` primeiro, depois `(data, hora, profissional)` — ordem de **domínio**, não
  do cliente (RN-42, doc 09 §3.6).

  ## Janela e regras (`fits_win`)

  A **janela** corta por período (RN-39): `:manha` rejeita `>= 12:00`, `:tarde` rejeita `< 12:00`.
  As **regras** (`AvailabilityRule`) restringem por dia-da-semana/data + faixa: sem regra
  **utilizável** (não-expirada e com faixa), tudo passa (o `-1` do protótipo, aqui `rule_index:
  nil`); com regras, a vaga precisa casar **alguma**, e o índice da que casou volta no slot (para
  a UI destacar a disponibilidade certa). Uma regra `:data` com data no passado **expira** e é
  ignorada (RN-38, relógio injetável).

  ## `DUR = 50` é constante

  O item de fila **não carrega tipo** (só "quero uma vaga"), então a varredura usa a duração fixa
  do protótipo (50 min). O tipo e a duração reais são escolhidos só na conversão, no modal.
  """

  alias Api.Scheduling.{Availability, Periods}

  # Constantes de `filaVagas` [:2534].
  @dur 50
  @days 14
  @step 30
  @cap 50
  @noon 720

  @typedoc "Uma vaga encontrada, em minutos locais desde a meia-noite."
  @type slot :: %{
          date: Date.t(),
          start: non_neg_integer(),
          dur: non_neg_integer(),
          professional_id: Ecto.UUID.t(),
          dow: non_neg_integer(),
          rule_index: non_neg_integer() | nil,
          freed: boolean()
        }

  @typedoc """
  A entrada já montada pelo wrapper do domínio (`Api.Waitlist.find_slots/2`):

    * `entry` — `%{janela, rules}` do item (as `rules` na ordem de exibição, o índice importa);
    * `professionals` — os candidatos já resolvidos (preferidos, ou todos os ativos);
    * `sources_by_prof` — `%{professional_id => Availability.sources}`;
    * `appts_by_prof_day` — `%{{professional_id, Date} => [%{start, end, freed}]}` (minutos locais);
    * `today` / `now_minutes` — o relógio do escopo (ADR-009), no fuso da clínica.
  """
  @type input :: %{
          entry: %{janela: atom(), rules: [map()]},
          professionals: [map()],
          sources_by_prof: %{Ecto.UUID.t() => Availability.sources()},
          appts_by_prof_day: %{{Ecto.UUID.t(), Date.t()} => [map()]},
          today: Date.t(),
          now_minutes: non_neg_integer()
        }

  @doc """
  Compõe o expediente de cada par `(profissional, dia)` **uma vez**.

  O resultado depende só de `(prof, date)` — nunca do item da fila. Chamado de dentro de
  `slots_for/7`, ele era recomposto por entry: com a página cheia (teto 200) e 15 profissionais
  ativos × 14 dias, eram **42.000 composições idênticas por request**, cada uma varrendo
  `clinic_exceptions`/`professional_exceptions`/`professional_hours` linearmente (doc 96, P-1).

  O moduledoc já tinha resolvido o N+1 de **banco** (`appts_index/5`); este é o N+1 de **CPU**,
  que ficou de pé. Materializado aqui, cai de `entries × N × 14` para `N × 14`.
  """
  @spec periods_index([map()], %{Ecto.UUID.t() => Availability.sources()}, Date.t()) ::
          %{{Ecto.UUID.t(), Date.t()} => term()}
  def periods_index(professionals, sources_by_prof, today) do
    for prof <- professionals,
        date <- date_window(today),
        into: %{} do
      {{prof.id, date},
       Availability.day_periods(date, prof, Map.get(sources_by_prof, prof.id, empty_sources()))}
    end
  end

  @spec find_slots(input()) :: [slot()]
  def find_slots(
        %{
          entry: entry,
          professionals: professionals,
          sources_by_prof: sources_by_prof,
          appts_by_prof_day: appts_by_prof_day,
          today: today,
          now_minutes: now_minutes
        } = input
      ) do
    # Sem índice pronto (uso avulso, teste de unidade), compõe o seu — o motor continua sendo
    # chamável com a entrada mínima.
    periods =
      Map.get_lazy(input, :periods_by_prof_day, fn ->
        periods_index(professionals, sources_by_prof, today)
      end)

    # `today` viaja dentro do `entry` para o `fits_win` decidir expiração/`usable_rules?` contra
    # o HOJE real (ADR-009), não contra a data do slot varrido.
    entry = Map.put(entry, :today, today)

    today
    |> date_window()
    |> scan_days(entry, professionals, periods, appts_by_prof_day, today, now_minutes)
    |> sort_slots()
  end

  defp date_window(today), do: Enum.map(0..(@days - 1), &Date.add(today, &1))

  # Acumula dia a dia e para depois do primeiro dia que cruza o teto (`out.length>=CAP` [:2588]).
  #
  # O acumulador é uma lista de blocos, invertida, com a contagem carregada ao lado: `acc ++
  # day_slots` seguido de `length(acc)` a cada dia era append quadrático — mitigado pelo `@cap`,
  # mas gratuito (doc 96, P-1).
  defp scan_days(dates, entry, professionals, periods, appts, today, now_min) do
    {blocos, _total} =
      Enum.reduce_while(dates, {[], 0}, fn date, {acc, total} ->
        day_slots =
          Enum.flat_map(professionals, fn prof ->
            slots_for(entry, prof, date, Date.diff(date, today), periods, appts, now_min)
          end)

        total = total + length(day_slots)
        acc = [day_slots | acc]

        if total >= @cap, do: {:halt, {acc, total}}, else: {:cont, {acc, total}}
      end)

    blocos |> Enum.reverse() |> Enum.concat()
  end

  defp slots_for(entry, prof, date, d_off, periods, appts, now_min) do
    case Map.get(periods, {prof.id, date}) do
      nil ->
        []

      {:closed, _reason} ->
        []

      {:open, periods} ->
        dow = dow(date)
        day_appts = Map.get(appts, {prof.id, date}, [])
        busy = for a <- day_appts, not a.freed, do: {a.start, a.end}
        freed = for a <- day_appts, a.freed, do: a

        pass1 = freed_slots(entry, prof.id, date, dow, d_off, periods, busy, freed, now_min)
        pass2 = general_slots(entry, prof.id, date, dow, d_off, periods, busy, now_min)

        # A passada 1 vence a geral no mesmo horário (dedup por `start` — `date`/`prof` já são
        # os mesmos aqui), fiel ao `seen` do protótipo que emite `freed` antes.
        starts = MapSet.new(pass1, & &1.start)
        pass1 ++ Enum.reject(pass2, &MapSet.member?(starts, &1.start))
    end
  end

  # Passada 1 — cada vaga que abriu vira um slot no horário exato liberado.
  defp freed_slots(entry, prof_id, date, dow, d_off, periods, busy, freed, now_min) do
    Enum.flat_map(freed, fn appt ->
      start = appt.start
      finish = start + @dur

      with false <- d_off == 0 and start < now_min,
           true <- in_period?(start, finish, periods),
           true <- free?(start, finish, busy),
           {:fit, rule_index} <- fits_win(entry, start, finish, date, dow) do
        [slot(date, start, prof_id, dow, rule_index, true)]
      else
        _ -> []
      end
    end)
  end

  # Passada 2 — a primeira brecha livre de cada período.
  defp general_slots(entry, prof_id, date, dow, d_off, periods, busy, now_min) do
    Enum.flat_map(periods, fn [ini, fim] ->
      first_gap(
        entry,
        prof_id,
        date,
        dow,
        d_off,
        Periods.to_minutes(ini),
        Periods.to_minutes(fim),
        busy,
        now_min
      )
    end)
  end

  defp first_gap(entry, prof_id, date, dow, d_off, start, period_end, busy, now_min) do
    cond do
      start + @dur > period_end ->
        []

      d_off == 0 and start < now_min ->
        step(entry, prof_id, date, dow, d_off, start, period_end, busy, now_min)

      true ->
        finish = start + @dur

        case fits_win(entry, start, finish, date, dow) do
          {:fit, rule_index} ->
            if free?(start, finish, busy),
              do: [slot(date, start, prof_id, dow, rule_index, false)],
              else: step(entry, prof_id, date, dow, d_off, start, period_end, busy, now_min)

          :no_fit ->
            step(entry, prof_id, date, dow, d_off, start, period_end, busy, now_min)
        end
    end
  end

  defp step(entry, prof_id, date, dow, d_off, start, period_end, busy, now_min) do
    first_gap(entry, prof_id, date, dow, d_off, start + @step, period_end, busy, now_min)
  end

  @doc """
  A vaga `[start, finish]` (minutos locais) em `date`/`dow` casa com a **janela + regras** de um
  item da fila? Ignora expediente e ocupação de propósito — é a pergunta do "quem cabe aqui?"
  (D-E5.4): a vaga que abriu por uma falta **já** está livre, então o que falta decidir é só se
  o paciente a **quer** (preferência de horário), não se ela existe.

  Corrige o casamento frouxo do protótipo, que filtrava só por profissional
  ([`:2252`](../../../interface/Movimento.dc.html#L2252)) e chamava de "compatível" quem não era.
  A preferência de **profissional** é checada por quem chama (`Api.Waitlist.who_fits/4`), não aqui.
  """
  @spec matches_slot?(
          map(),
          non_neg_integer(),
          non_neg_integer(),
          Date.t(),
          non_neg_integer(),
          Date.t()
        ) ::
          boolean()
  def matches_slot?(entry, start, finish, %Date{} = date, dow, %Date{} = today) do
    fits_win(%{janela: entry.janela, rules: entry.rules, today: today}, start, finish, date, dow) !=
      :no_fit
  end

  # ---- Janela + regras (`fitsWin` [:2542]) ----

  # `{:fit, rule_index | nil}` (nil = sem restrição de regra, o `-1`) | `:no_fit`.
  @spec fits_win(map(), non_neg_integer(), non_neg_integer(), Date.t(), non_neg_integer()) ::
          {:fit, non_neg_integer() | nil} | :no_fit
  defp fits_win(%{janela: janela, rules: rules, today: today}, start, finish, date, dow) do
    cond do
      janela == :manha and start >= @noon -> :no_fit
      janela == :tarde and start < @noon -> :no_fit
      usable_rules?(rules, today) -> match_rules(rules, start, finish, date, dow, today)
      # Sem regra utilizável, tudo passa (o `-1` do protótipo).
      true -> {:fit, nil}
    end
  end

  defp usable_rules?(rules, today) do
    Enum.any?(rules, fn rule -> not expired?(rule, today) and rule.periodos != [] end)
  end

  # O índice é na lista de regras **como veio** (a UI mostra todas, inclusive expiradas, e casa
  # por índice) — fiel ao `findIndex` sobre `f.regras` do protótipo [:2545].
  defp match_rules(rules, start, finish, date, dow, today) do
    rules
    |> Enum.with_index()
    |> Enum.find_value(:no_fit, fn {rule, index} ->
      if rule_matches?(rule, start, finish, date, dow, today), do: {:fit, index}, else: false
    end)
  end

  defp rule_matches?(rule, start, finish, date, dow, today) do
    not expired?(rule, today) and day_matches?(rule, date, dow) and
      period_contains?(rule.periodos, start, finish)
  end

  defp day_matches?(%{tipo: :data, data: data}, date, _dow), do: data == date
  defp day_matches?(%{tipo: :semana, dows: dows}, _date, dow), do: dow in dows

  defp period_contains?(periodos, start, finish) do
    Enum.any?(periodos, fn [ini, fim] ->
      start >= Periods.to_minutes(ini) and finish <= Periods.to_minutes(fim)
    end)
  end

  defp expired?(%{tipo: :data, data: %Date{} = data}, today), do: Date.compare(data, today) == :lt
  defp expired?(_rule, _today), do: false

  # ---- Utilidades ----

  defp in_period?(start, finish, periods) do
    Enum.any?(periods, fn [ini, fim] ->
      start >= Periods.to_minutes(ini) and finish <= Periods.to_minutes(fim)
    end)
  end

  defp free?(start, finish, busy) do
    not Enum.any?(busy, fn {b_start, b_end} -> start < b_end and b_start < finish end)
  end

  defp slot(date, start, prof_id, dow, rule_index, freed) do
    %{
      date: date,
      start: start,
      dur: @dur,
      professional_id: prof_id,
      dow: dow,
      rule_index: rule_index,
      freed: freed
    }
  end

  # `freed` primeiro, depois data (cronológica via `to_erl`, não a ordem estrutural do struct),
  # hora e profissional — a ordenação de domínio do `out.sort` [:2591].
  defp sort_slots(slots) do
    Enum.sort_by(slots, fn s ->
      {if(s.freed, do: 0, else: 1), Date.to_erl(s.date), s.start, s.professional_id}
    end)
  end

  defp dow(date), do: Api.Scheduling.LocalTime.dow(date)

  defp empty_sources do
    %{
      clinic_hours: [],
      professional_hours: [],
      clinic_exceptions: [],
      professional_exceptions: []
    }
  end
end
