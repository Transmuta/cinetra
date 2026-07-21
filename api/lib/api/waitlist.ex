defmodule Api.Waitlist do
  @moduledoc """
  Domínio da **fila de espera** (doc 25, Entrega 5) — recursos por-tenant por atributo
  (`clinic_id`, ADR-017), no molde de `Api.Scheduling`. Concentra o item da fila
  (`WaitlistEntry` + suas `AvailabilityRule`), o motor de vagas (`SlotFinder`, port do
  `filaVagas`) e a orquestração de oferta→conversão (com o `Api.Scheduling.SlotHold`).

  Como em `Api.Scheduling`, os **wrappers deste módulo** centralizam o `Api.Repo.with_clinic/2`
  (GUC de tenant para a RLS, ADR-018) na leitura — por isso os controllers chamam estas funções,
  não as code interfaces cruas. A escrita seta a GUC dentro da própria ação (`SetTenantGuc`).
  """
  use Ash.Domain, otp_app: :api

  import Api.Tenancy, only: [in_clinic: 2]

  alias Api.Scheduling.LocalTime
  alias Api.Waitlist.SlotFinder

  require Ash.Query

  resources do
    resource Api.Waitlist.WaitlistEntry do
      define :list_waitlist_entries, action: :read
      define :get_waitlist_entry, action: :read, get_by: [:id]
      define :enqueue_waitlist_entry, action: :enqueue
      define :update_waitlist_entry, action: :update
      define :dequeue_waitlist_entry, action: :dequeue
    end

    resource Api.Waitlist.AvailabilityRule do
      define :list_availability_rules, action: :read
    end
  end

  # ---- Fila: leitura ----

  @doc """
  A fila da clínica ativa, ordenada por **prioridade** (urgente → baixa) e, dentro da mesma
  prioridade, pelo tempo de espera (mais antigo primeiro). Cada item traz suas regras e o
  paciente (projeção enxuta + agregado de faltas, para o cartão do "quem cabe").

  A ordenação é de **domínio**, não `?sort` do cliente (doc 09 §3.6): a fila tem uma ordem certa,
  e o Postgres ordena o enum pela string armazenada — por isso o rank é aplicado em Elixir.
  """
  def list_entries(%Api.Scope{} = scope, opts \\ []) do
    in_clinic(scope, fn ->
      entries =
        list_waitlist_entries!(scope: scope, load: entry_load(), query: build_query(opts))
        |> sort_by_priority()

      # Os profissionais ativos vão junto pelo mesmo motivo do `GET /api/appointments`: a tela
      # mostra os "preferidos" por nome e o "quem cabe" precisa das colunas — e é dela que sai o
      # mapa id→nome. Uma leitura só, na mesma transação/GUC.
      %{
        entries: entries,
        professionals:
          Api.Directory.list_professionals!(scope: scope, query: [filter: [ativo: true]])
      }
    end)
  end

  @doc "Um item da fila por id, com regras e paciente carregados — ou `nil` (fora do tenant → 404)."
  def get_entry(%Api.Scope{} = scope, id) when is_binary(id) do
    in_clinic(scope, fn ->
      get_waitlist_entry(id, scope: scope, load: entry_load(), not_found_error?: false)
    end)
  end

  # O que todo item de fila carrega para a tela: as regras e o paciente numa projeção enxuta
  # (nome/telefone) + o agregado `faltas`. Sem `select` o cadastro traria as ~39 colunas (CPF,
  # RG, prefs) por item — mesma economia de `Api.Scheduling.patients_for/2`.
  defp entry_load do
    patient_query =
      Api.Records.Patient
      |> Ash.Query.select([:id, :nome, :tel, :ativo])
      |> Ash.Query.load([:faltas])

    [:rules, patient: patient_query]
  end

  defp build_query(opts) do
    case Keyword.get(opts, :prio) do
      nil -> []
      prio -> [filter: [prio: prio]]
    end
  end

  # ---- Fila: escrita ----

  @doc """
  Adiciona (ou **atualiza**, se o paciente já está na fila) um item — o `addFila` do protótipo,
  que faz upsert por paciente. `attrs` traz `patient_id`, `prio`, `janela`, `professional_ids`,
  `obs` e `rules` (lista de mapas). Devolve o item recarregado com regras e paciente.
  """
  def enqueue_entry(%Api.Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, entry} <- enqueue_waitlist_entry(attrs, scope: scope) do
      {:ok, reload_entry(scope, entry)}
    end
  end

  @doc "Edita um item existente (prioridade, janela, preferidos, regras). Fora do tenant → 404."
  def update_entry(%Api.Scope{} = scope, id, attrs) when is_binary(id) and is_map(attrs) do
    with {:ok, entry} <- fetch_entry(scope, id),
         {:ok, updated} <- update_waitlist_entry(entry, attrs, scope: scope) do
      {:ok, reload_entry(scope, updated)}
    end
  end

  @doc "Remove um item da fila (à mão, pela lixeira). Fora do tenant → 404."
  def dequeue_entry(%Api.Scope{} = scope, id) when is_binary(id) do
    with {:ok, entry} <- fetch_entry(scope, id) do
      dequeue_waitlist_entry(entry, scope: scope)
    end
  end

  # Fetch sob a GUC (leitura precisa dela). `{:error, :not_found}` para fora-do-tenant/inexistente,
  # que o controller traduz em 404 — mesmo caminho de `transition_appointment/5`.
  defp fetch_entry(scope, id) do
    case in_clinic(scope, fn ->
           get_waitlist_entry(id, scope: scope, not_found_error?: false)
         end) do
      {:ok, %{} = entry} -> {:ok, entry}
      _ -> {:error, :not_found}
    end
  end

  # A escrita não vem com as relações carregadas; recarrega uma vez para sair por todas as portas
  # com a mesma forma (rules + patient). Leitura, então sob `in_clinic`.
  defp reload_entry(scope, entry) do
    in_clinic(scope, fn -> Ash.load!(entry, entry_load(), scope: scope) end)
  end

  # ---- Oferta e conversão (SlotHold) ----

  @doc """
  Segura a vaga por 10 min (POST /waitlist/:id/offer). `attrs`: `professional_id`, `starts_at`,
  `duration_minutos` (default 50). Devolve `{:ok, hold}`, ou `{:error, {:slot_held, meta}}` quando
  outra reserva **viva** já cobre o horário daquele profissional — o 409 com quem segura e até
  quando (doc 09 §6.2). Outros erros (validação) sobem como `{:error, changeset}`.
  """
  def offer_slot(%Api.Scope{} = scope, entry, attrs) when is_map(attrs) do
    hold_attrs = %{
      professional_id: Map.get(attrs, :professional_id),
      starts_at: Map.get(attrs, :starts_at),
      waitlist_entry_id: entry.id,
      duration_minutos: Map.get(attrs, :duration_minutos) || 50
    }

    case Api.Scheduling.create_slot_hold(hold_attrs, scope: scope) do
      {:ok, hold} -> {:ok, hold}
      {:error, error} -> classify_hold_error(scope, error, hold_attrs)
    end
  end

  # A violação da exclusion constraint vira `{:slot_held, meta}` (→ 409). Qualquer outro erro
  # (ex.: validação de campo) sobe como está (→ 422/400 na fronteira).
  defp classify_hold_error(scope, error, hold_attrs) do
    if slot_held_error?(error),
      do: {:error, {:slot_held, hold_meta(scope, hold_attrs)}},
      else: {:error, error}
  end

  defp slot_held_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &(Map.get(&1, :message) == Api.Scheduling.SlotHold.slot_held_message()))
  end

  defp slot_held_error?(_error), do: false

  # Quem segura a vaga conflitante (a reserva viva que sobrepõe o horário pedido). Depois da purga
  # in-transaction ter sido desfeita pelo rollback, os vencidos voltam — por isso o filtro por
  # `expires_at > agora` (relógio do banco, como a purga), para não apontar um hold morto.
  defp hold_meta(scope, %{professional_id: prof_id, starts_at: starts_at, duration_minutos: dur}) do
    ends_at = DateTime.add(starts_at, dur * 60, :second)

    in_clinic(scope, fn ->
      query =
        Ash.Query.filter(
          Api.Scheduling.SlotHold,
          professional_id == ^prof_id and starts_at < ^ends_at and ends_at > ^starts_at
        )

      now = DateTime.utc_now()

      Api.Scheduling.list_slot_holds!(scope: scope, query: query, load: [:held_by])
      |> Enum.find(&(DateTime.compare(&1.expires_at, now) == :gt))
      |> hold_to_meta()
    end)
  end

  defp hold_to_meta(nil), do: %{}

  defp hold_to_meta(hold) do
    %{
      held_by: %{id: hold.held_by_id, nome: hold.held_by && hold.held_by.nome},
      expires_at: hold.expires_at
    }
  end

  @doc """
  Converte um item da fila em agendamento (POST /waitlist/:id/convert): cria o bloco para o
  paciente do item pelo `Api.Scheduling.schedule_appointment/2` e **remove o item da fila** (o
  hold, se houver, sai junto pelo cascade da FK). `appt_attrs`: `starts_at`, `professional_id`,
  `appointment_type_id`, `encaixe`, `obs`, `duration_minutos` — o `patient_ids` é o paciente do item.

  Funciona **com ou sem** oferta prévia (o "agendar manualmente" da fila não passa por offer).
  Propaga o 422/`schedule_conflict` de `schedule_appointment` quando o horário foi tomado nesse
  meio-tempo.
  """
  def convert(%Api.Scope{} = scope, entry, appt_attrs) when is_map(appt_attrs) do
    attrs = Map.put(appt_attrs, :patient_ids, [entry.patient_id])

    with {:ok, appointment} <- Api.Scheduling.schedule_appointment(attrs, scope: scope) do
      # O paciente saiu da fila (o hold vai junto pelo cascade). Best-effort: o agendamento é o
      # que importa — um item órfão a recepção remove à mão, um agendamento perdido não volta.
      _ = dequeue_entry(scope, entry.id)
      {:ok, appointment}
    end
  end

  # ---- Motor de vagas (find_slots) ----

  @doc """
  As vagas compatíveis com um item da fila (GET /waitlist/:id/slots) — o `filaVagas` do protótipo,
  agora sobre dado real. Carrega os profissionais candidatos (os preferidos ∩ ativos, ou todos os
  ativos), as fontes de expediente e os agendamentos da janela de 14 dias, e delega ao motor puro
  `Api.Waitlist.SlotFinder` com o **relógio do escopo** (ADR-009) no fuso da clínica.

  A leitura de agendamentos é **invariante** (`authorize?: false`), não a recortada por A7: as
  vagas são o que está de fato livre na clínica, não a agenda "do profissional". Sob o recorte,
  um profissional veria as colunas dos colegas como vazias e ofereceria vagas já ocupadas —
  mesmo motivo de `Api.Scheduling.count_participants/2` ler sem escopo.
  """
  def find_slots(%Api.Scope{} = scope, entry) do
    %{timezone: tz, today: today, now_minutes: now_minutes} = Api.Scheduling.clinic_now(scope)
    to = Date.add(today, 13)

    in_clinic(scope, fn ->
      active_by_id =
        Api.Directory.list_professionals!(scope: scope, query: [filter: [ativo: true]])
        |> Map.new(&{&1.id, &1})

      case candidate_ids(entry, active_by_id) do
        [] ->
          []

        ids ->
          {:ok, pairs} = Api.Scheduling.load_availability_window(scope.clinic_id, ids, today, to)
          {from_utc, to_utc} = LocalTime.window!(today, to, tz)

          SlotFinder.find_slots(%{
            entry: %{janela: entry.janela, rules: entry.rules},
            professionals: Enum.map(pairs, fn {prof, _} -> prof end),
            sources_by_prof: Map.new(pairs, fn {prof, sources} -> {prof.id, sources} end),
            appts_by_prof_day: appts_index(scope, from_utc, to_utc, ids, tz),
            today: today,
            now_minutes: now_minutes
          })
      end
    end)
  end

  # Preferidos ∩ ativos, ou todos os ativos quando não há preferido (RN-37). Preferido que não
  # existe/está inativo é **ignorado**, não erro — fiel ao `.filter(p=>p&&p.ativo)` do protótipo.
  defp candidate_ids(entry, active_by_id) do
    case entry.professional_ids do
      ids when is_list(ids) and ids != [] -> Enum.filter(ids, &Map.has_key?(active_by_id, &1))
      _ -> Map.keys(active_by_id)
    end
  end

  # `%{{professional_id, data local} => [%{start, end, freed}]}` em minutos locais. `freed` são os
  # `cancelado`/`faltou` (viram vaga que abriu); os demais ocupam. Leitura invariante (ver acima).
  defp appts_index(scope, from_utc, to_utc, ids, tz) do
    Api.Scheduling.list_appointments!(from_utc, to_utc, %{professional_ids: ids},
      tenant: scope.clinic_id,
      authorize?: false
    )
    |> Enum.group_by(
      fn appt -> {appt.professional_id, LocalTime.to_local_date(appt.starts_at, tz)} end,
      fn appt ->
        start = LocalTime.to_local_minutes(appt.starts_at, tz)
        duracao = div(DateTime.diff(appt.ends_at, appt.starts_at, :second), 60)
        %{start: start, end: start + duracao, freed: appt.status in [:cancelado, :faltou]}
      end
    )
  end

  # ---- Quem cabe aqui? (falta → fila, RN-45 / D-E5.4) ----

  @doc """
  Os itens da fila que **cabem** numa vaga que abriu (o "quem cabe aqui?" que o drawer abre ao
  marcar uma falta numa sessão já iniciada). O slot é `{professional_id, starts_at, ends_at}` do
  agendamento que virou falta. Devolve os itens cuja **preferência de profissional** inclui esse
  profissional (ou é vazia) **e** cuja **janela + regras** casam com o horário — o motor
  (`SlotFinder.matches_slot?/6`) decide o casamento, não o cliente. Ordenado por prioridade.

  Divergência deliberada do protótipo (D-E5.4): lá o casamento era só por profissional
  ([`:2252`](../../../interface/Movimento.dc.html#L2252)) e o rótulo "compatíveis" mentia. A vaga
  já está livre (foi uma falta), então não se checa expediente nem ocupação — só a preferência.
  """
  def who_fits(%Api.Scope{} = scope, professional_id, %DateTime{} = starts_at, %DateTime{} = ends_at, clock \\ nil)
      when is_binary(professional_id) do
    # `clock` opcional: o controller já o computou (`clinic_now`) para o JSON, então o passa — sem
    # ele, `candidates` leria a clínica duas vezes por request (bate-volta E5, D1).
    %{timezone: tz, today: today} = clock || Api.Scheduling.clinic_now(scope)
    date = LocalTime.to_local_date(starts_at, tz)
    start = LocalTime.to_local_minutes(starts_at, tz)
    finish = start + div(DateTime.diff(ends_at, starts_at, :second), 60)
    dow = rem(Date.day_of_week(date), 7)

    in_clinic(scope, fn ->
      list_waitlist_entries!(scope: scope, load: entry_load())
      |> Enum.filter(fn entry ->
        prof_preferred?(entry, professional_id) and
          SlotFinder.matches_slot?(entry, start, finish, date, dow, today)
      end)
      |> sort_by_priority()
    end)
  end

  defp prof_preferred?(%{professional_ids: []}, _professional_id), do: true
  defp prof_preferred?(%{professional_ids: ids}, professional_id), do: professional_id in ids

  # ---- Ordenação de domínio ----

  @doc """
  O posto de uma prioridade para ordenação (urgente = 0, mais alto = mais cedo na fila). O
  Postgres ordenaria o enum alfabeticamente (`alta, baixa, normal, urgente`), que não é a ordem
  de urgência — por isso a fila ordena em Elixir por este rank.
  """
  def priority_rank(:urgente), do: 0
  def priority_rank(:alta), do: 1
  def priority_rank(:normal), do: 2
  def priority_rank(:baixa), do: 3

  defp sort_by_priority(entries) do
    Enum.sort_by(entries, &{priority_rank(&1.prio), &1.inserted_at})
  end
end
