defmodule ApiWeb.WaitlistController do
  @moduledoc """
  A fila de espera (doc 25, Entrega 5 / doc 09 §3.6). Molde do `AppointmentsController`:
  `with_member_scope` na fronteira (o RBAC fino é da policy do recurso), `whitelist/2` no corpo,
  `error_response/2` na escada 401/403/404/422, e o **409 `slot_held`** com meta para a corrida da
  oferta (doc 09 §6.2). `clinic_id` nunca vem do corpo — é do `Ash.Scope`.
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Waitlist
  alias ApiWeb.WaitlistJSON

  # GET /api/waitlist?limit=&offset=
  def index(conn, params) do
    with_member_scope(conn, fn scope ->
      %{entries: entries, professionals: professionals, page: page} =
        Waitlist.list_entries(scope, opcoes(params))

      {today, tz} = clock(scope)

      json(conn, %{
        waitlist: Enum.map(entries, &WaitlistJSON.entry(&1, today, tz)),
        professionals: Enum.map(professionals, &WaitlistJSON.professional/1),
        # Data local de hoje (ADR-009): a lista marca a regra `:data` no passado como expirada
        # (tracejada) sem refazer o cálculo de fuso no cliente.
        today: Date.to_iso8601(today),
        # F6: o "X–Y de Z" da tela. Os tetos são do domínio (`Api.Waitlist`), não daqui — a
        # fronteira só converte a string do query param em inteiro.
        page: page,
        # As contagens da sidebar vêm do servidor **porque** a lista é paginada: contar o que
        # chegou contaria só a página.
        counts: Waitlist.entry_counts(scope),
        # F4: as reservas vivas da clínica — a tela marca "alguém está oferecendo esta vaga".
        # Da clínica inteira, não da página: a vaga reservada pode ser de um item que não está
        # nesta página, e o chip que ela bloqueia pode estar.
        holds: Enum.map(Waitlist.live_holds(scope), &WaitlistJSON.hold/1)
      })
    end)
  end

  # `?limit=`, `?offset=` e `?prio=` chegam como string. Valor inválido é IGNORADO (cai no default
  # do domínio) em vez de virar 422: paginação torta na URL não é erro do usuário a ponto de
  # esconder a fila dele.
  #
  # O `prio` filtra **no servidor** desde o F6, e não mais no cliente: com a lista paginada,
  # filtrar a página traria "os urgentes que por acaso caíram nesta página", e o total do rodapé
  # contaria outra coisa que a lista mostra.
  defp opcoes(params) do
    [
      limit: inteiro(params["limit"]),
      offset: inteiro(params["offset"]),
      prio: prio(params["prio"])
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @prioridades ~w(urgente alta normal baixa)

  defp prio(value) when value in @prioridades, do: String.to_existing_atom(value)
  defp prio(_value), do: nil

  defp inteiro(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp inteiro(value) when is_integer(value), do: value
  defp inteiro(_value), do: nil

  # POST /api/waitlist  (upsert por paciente)
  def create(conn, params) do
    with_member_scope(conn, fn scope ->
      attrs =
        params
        |> whitelist([:patient_id, :prio, :janela, :obs, :professional_ids])
        |> Map.put(:rules, params["rules"] || [])

      case Waitlist.enqueue_entry(scope, attrs) do
        {:ok, entry} -> conn |> put_status(:created) |> render_entry(scope, entry)
        {:error, error} -> error_response(conn, error)
      end
    end)
  end

  # PATCH /api/waitlist/:id
  def update(conn, %{"id" => id} = params) do
    with_member_scope(conn, fn scope ->
      attrs =
        params
        |> whitelist([:prio, :janela, :obs, :professional_ids])
        |> maybe_put_rules(params)

      case Waitlist.update_entry(scope, id, attrs) do
        {:ok, entry} -> render_entry(conn, scope, entry)
        {:error, :not_found} -> not_found(conn)
        {:error, error} -> error_response(conn, error)
      end
    end)
  end

  # DELETE /api/waitlist/:id
  def delete(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      case Waitlist.dequeue_entry(scope, id) do
        :ok -> send_resp(conn, :no_content, "")
        {:error, :not_found} -> not_found(conn)
        {:error, error} -> error_response(conn, error)
      end
    end)
  end

  # GET /api/waitlist/slots?limit=&offset=  — o motor em lote (sem N+1) para a página visível
  #
  # Aceita a MESMA paginação de `index/2` de propósito: com a fila paginada (F6), calcular vagas
  # para a fila inteira seria trabalho jogado fora — a tela só desenha o chip de quem está na
  # página. O cliente pede a mesma janela nas duas chamadas.
  def all_slots(conn, params) do
    with_member_scope(conn, fn scope ->
      %{entries: entries} = Waitlist.list_entries(scope, opcoes(params))
      by_entry = Waitlist.slots_by_entry(scope, entries)

      json(conn, %{
        slots_by_entry:
          Map.new(by_entry, fn {id, slots} -> {id, Enum.map(slots, &WaitlistJSON.slot/1)} end)
      })
    end)
  end

  # GET /api/waitlist/:id/slots  — o motor `find_slots`
  def slots(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      case Waitlist.get_entry(scope, id) do
        {:ok, entry} when not is_nil(entry) ->
          slots = Waitlist.find_slots(scope, entry)
          json(conn, %{slots: Enum.map(slots, &WaitlistJSON.slot/1)})

        _ ->
          not_found(conn)
      end
    end)
  end

  # GET /api/waitlist/candidates?professional_id=&starts_at=&ends_at=  — "quem cabe aqui?"
  def candidates(conn, params) do
    with_member_scope(conn, fn scope ->
      case candidate_params(params) do
        {:ok, professional_id, starts_at, ends_at} ->
          # Um relógio só, passado ao motor E usado no JSON — sem reler a clínica (D1).
          clock = Api.Scheduling.clinic_now(scope)
          entries = Waitlist.who_fits(scope, professional_id, starts_at, ends_at, clock)

          json(conn, %{
            candidates: Enum.map(entries, &WaitlistJSON.entry(&1, clock.today, clock.timezone))
          })

        :error ->
          invalid(conn, "informe professional_id, starts_at e ends_at (ISO)")
      end
    end)
  end

  # POST /api/waitlist/:id/offer  — segura a vaga (409 slot_held sob corrida)
  def offer(conn, %{"id" => id} = params) do
    with_member_scope(conn, fn scope ->
      with {:ok, entry} <- fetch(scope, id),
           attrs = offer_attrs(params),
           {:ok, hold} <- Waitlist.offer_slot(scope, entry, attrs) do
        conn |> put_status(:created) |> json(%{hold: WaitlistJSON.hold(hold)})
      else
        {:error, :not_found} ->
          not_found(conn)

        {:error, {:slot_held, meta}} ->
          conflict(conn, "slot_held", held_message(meta), hold_meta_json(meta))

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # POST /api/waitlist/:id/convert  — vira agendamento e sai da fila
  def convert(conn, %{"id" => id} = params) do
    with_member_scope(conn, fn scope ->
      with {:ok, entry} <- fetch(scope, id),
           attrs =
             whitelist(params, [
               :starts_at,
               :professional_id,
               :appointment_type_id,
               :encaixe,
               :obs,
               :duration_minutos
             ]),
           {:ok, appt} <- Waitlist.convert(scope, entry, attrs) do
        conn |> put_status(:created) |> json(%{appointment: ApiWeb.AgendaJSON.appointment(appt)})
      else
        {:error, :not_found} -> not_found(conn)
        {:error, error} -> error_response(conn, error)
      end
    end)
  end

  # ---- helpers ----

  defp fetch(scope, id) do
    case Waitlist.get_entry(scope, id) do
      {:ok, %{} = entry} -> {:ok, entry}
      _ -> {:error, :not_found}
    end
  end

  defp render_entry(conn, scope, entry) do
    {today, tz} = clock(scope)
    json(conn, %{entry: WaitlistJSON.entry(entry, today, tz)})
  end

  # `{today, tz}` para o `dias_na_fila` — o relógio do escopo (ADR-009) no fuso da clínica,
  # via a fonte única `Api.Scheduling.clinic_now/1` (D1).
  defp clock(scope) do
    %{today: today, timezone: tz} = Api.Scheduling.clinic_now(scope)
    {today, tz}
  end

  # `rules` só é tocado quando veio no corpo (PATCH parcial não apaga as regras por omissão).
  defp maybe_put_rules(attrs, params) do
    case params["rules"] do
      nil -> attrs
      rules -> Map.put(attrs, :rules, rules)
    end
  end

  defp offer_attrs(params) do
    %{
      professional_id: params["professional_id"],
      starts_at: parse_datetime(params["starts_at"]),
      duration_minutos: params["duration_minutos"] || params["duration"] || 50
    }
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp candidate_params(params) do
    with prof when is_binary(prof) <- params["professional_id"],
         %DateTime{} = starts_at <- parse_datetime(params["starts_at"]),
         %DateTime{} = ends_at <- parse_datetime(params["ends_at"]) do
      {:ok, prof, starts_at, ends_at}
    else
      _ -> :error
    end
  end

  defp held_message(%{held_by: %{nome: nome}}) when is_binary(nome),
    do: "#{first_name(nome)} está oferecendo este horário."

  defp held_message(_meta), do: "Este horário já está reservado."

  defp first_name(nome), do: nome |> String.split(" ", parts: 2) |> hd()

  # Serializa o meta do 409: quem segura e até quando (doc 09 §6.2).
  defp hold_meta_json(%{held_by: held_by, expires_at: %DateTime{} = expires_at}) do
    %{held_by: held_by, expires_at: DateTime.to_iso8601(expires_at)}
  end

  defp hold_meta_json(_meta), do: %{}
end
