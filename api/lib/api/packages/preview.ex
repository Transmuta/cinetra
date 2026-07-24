defmodule Api.Packages.Preview do
  @moduledoc """
  A **prévia síncrona** da criação de um pacote (Fatia 3): projeta a série e classifica cada
  ocorrência **sem escrever nada**. É o `occIssue`/save-gate do protótipo
  ([`:703`](../../../../interface/Movimento.dc.html#L703)) portado para o servidor: a tela pede a
  prévia, mostra a lista com os problemas de cada dia, e só então confirma — com ou sem "encaixe".

  Separar isto da materialização é o que resolve o descompasso entre "criar é assíncrono (Oban)" e
  "o usuário precisa ver os conflitos antes de salvar": a prévia é rápida e read-only; o job só
  materializa o que foi confirmado.

  ## O que classifica

    * `:feriado` — dia de exceção `:fechado` da clínica; a série pula e estende (RN-19). Informativo.
    * `:fora_expediente` — não cabe no expediente das 4 camadas (`Api.Scheduling.Availability`).
    * `:conflito` — sobrepõe um agendamento existente do profissional (individual).
    * `:cheia` — a turma coincidente já bateu a capacidade.
    * `:join` — entra numa turma coincidente com vaga (não bloqueia — vira merge na materialização).
    * `:ok` — slot livre.

  `:fora_expediente`, `:conflito` e `:cheia` **bloqueiam** o save (salvo "agendar mesmo assim",
  que é decisão da tela, não daqui). `:feriado`, `:join` e `:ok` não.

  ## Fronteira com a materialização

  A prévia **não reserva** os slots: entre vê-la e confirmar, alguém pode ocupar um horário. A
  garantia continua sendo a exclusion constraint no momento da escrita (A5) — a prévia é conselho,
  não trava, exatamente como a pré-checagem de conflito do agendamento avulso.
  """

  import Api.Tenancy, only: [in_clinic: 2]

  alias Api.Scheduling.{Availability, LocalTime}

  @bloqueantes [:fora_expediente, :conflito, :cheia]

  @typedoc "Uma ocorrência classificada, como a tela desenha."
  @type ocorrencia :: %{
          data: Date.t(),
          hhmm: String.t(),
          starts_at: DateTime.t(),
          ends_at: DateTime.t(),
          feriado?: boolean(),
          issue: :feriado | :fora_expediente | :conflito | :cheia | :join | :ok,
          bloqueia?: boolean()
        }

  @doc """
  Roda a prévia para os `params` da criação (mesma forma do `create_package`, menos os campos que
  não afetam o calendário): `%{total, data_inicio, appointment_type_id, grade: %{dows, horarios,
  professional_id}}`.

  Devolve `{:ok, %{ocorrencias: [...], bloqueios: n, pode_salvar?: bool}}` ou o `{:error, motivo}`
  do motor de série (`Api.Packages.Series`) — grade vazia, horário faltando, etc.
  """
  @spec run(Api.Scope.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(%Api.Scope{} = scope, params) do
    %{
      total: total,
      data_inicio: data_inicio,
      appointment_type_id: type_id,
      grade: %{professional_id: professional_id} = grade
    } = normalize(params)

    clinic_id = scope.clinic_id

    in_clinic(scope, fn ->
      %{timezone: tz} = Api.Scheduling.load_clinic(clinic_id)
      tipo = load_type(scope, clinic_id, type_id)
      feriados = Api.Scheduling.clinic_holidays(clinic_id)

      with {:ok, ocorrencias} <- Api.Packages.Series.project(data_inicio, grade, total, feriados) do
        stamped = Enum.map(ocorrencias, &stamp_times(&1, tipo.duracao, tz))
        {first, last} = date_span(stamped)

        avail = availability_by_date(clinic_id, professional_id, first, last, tz)
        existing = existing_blocks(scope, professional_id, first, last, tz)

        classified =
          Enum.map(stamped, fn occ ->
            issue = classify(occ, dentro?(avail, occ, tz), existing, tipo)

            occ
            |> Map.take([:data, :hhmm, :starts_at, :ends_at, :feriado?])
            |> Map.merge(%{issue: issue, bloqueia?: issue in @bloqueantes})
          end)

        bloqueios = Enum.count(classified, & &1.bloqueia?)
        {:ok, %{ocorrencias: classified, bloqueios: bloqueios, pode_salvar?: bloqueios == 0}}
      end
    end)
  end

  @doc """
  Classifica **uma** ocorrência. Puro: recebe se cabe no expediente, os blocos existentes e o
  tipo — sem tocar em banco. Ver os valores possíveis no moduledoc.
  """
  @spec classify(map(), boolean(), [map()], map()) :: atom()
  def classify(%{feriado?: true}, _dentro?, _existing, _tipo), do: :feriado
  def classify(_occ, false, _existing, _tipo), do: :fora_expediente

  def classify(occ, true, existing, tipo) do
    sobrepostos =
      Enum.filter(existing, fn b -> b.status != :cancelado and overlap?(b, occ) end)

    conflito(sobrepostos, occ, tipo)
  end

  defp conflito([], _occ, _tipo), do: :ok

  defp conflito(sobrepostos, occ, %{grupo: true, id: type_id, capacidade: cap}) do
    case Enum.find(sobrepostos, &coincide_turma?(&1, occ, type_id)) do
      nil -> :conflito
      %{participantes: n} when n >= cap -> :cheia
      _ -> :join
    end
  end

  defp conflito(_sobrepostos, _occ, _tipo), do: :conflito

  # Coincidência de turma (a mesma linha em que o participante entra): mesmo tipo e mesmo início
  # (RN-18, o `findIndex` do protótipo em [`:349`](../../../../interface/Movimento.dc.html#L349)).
  defp coincide_turma?(bloco, occ, type_id) do
    bloco.appointment_type_id == type_id and
      DateTime.compare(bloco.starts_at, occ.starts_at) == :eq
  end

  defp overlap?(bloco, occ) do
    DateTime.compare(bloco.starts_at, occ.ends_at) == :lt and
      DateTime.compare(bloco.ends_at, occ.starts_at) == :gt
  end

  # ---- carregamento ----

  defp normalize(params) do
    grade = Map.fetch!(params, :grade)

    %{
      total: Map.fetch!(params, :total),
      data_inicio: Map.fetch!(params, :data_inicio),
      appointment_type_id: Map.fetch!(params, :appointment_type_id),
      grade: %{
        dows: Map.fetch!(grade, :dows),
        # `Series.project` normaliza as chaves string do `horarios` — não repetir aqui.
        horarios: Map.fetch!(grade, :horarios),
        professional_id: Map.fetch!(grade, :professional_id)
      }
    }
  end

  defp load_type(scope, clinic_id, type_id) do
    tipo = Api.Directory.get_appointment_type!(type_id, scope: scope)

    # `group_capacity` devolve `:individual` para tipo individual — capacidade só é consultada por
    # `classify` no ramo `grupo: true`, então `nil` fora dele é inofensivo.
    capacidade =
      case Api.Scheduling.group_capacity(clinic_id, type_id) do
        {:ok, cap} -> cap
        _ -> nil
      end

    %{id: tipo.id, grupo: tipo.grupo, capacidade: capacidade, duracao: tipo.duracao_minutos}
  end

  defp stamp_times(occ, duracao, tz) do
    {:ok, starts_at} = LocalTime.to_utc(occ.data, occ.hhmm, tz)
    ends_at = DateTime.add(starts_at, duracao * 60, :second)
    Map.merge(occ, %{starts_at: starts_at, ends_at: ends_at})
  end

  defp date_span(occ) do
    datas = Enum.map(occ, & &1.data)
    {Enum.min(datas, Date), Enum.max(datas, Date)}
  end

  # Mapa `date => {professional, sources}` para consultar o expediente de cada ocorrência sem
  # recarregar. `load_availability_window/4` já lê as 4 fontes numa janela só.
  defp availability_by_date(clinic_id, professional_id, from, to, _tz) do
    {:ok, [{professional, sources}]} =
      Api.Scheduling.load_availability_window(clinic_id, [professional_id], from, to)

    {professional, sources}
  end

  defp dentro?({professional, sources}, occ, tz) do
    case Availability.day_periods(occ.data, professional, sources) do
      {:closed, _} ->
        false

      {:open, periods} ->
        Availability.fits?(periods, LocalTime.to_local_range(occ.starts_at, occ.ends_at, tz))
    end
  end

  # Os blocos do profissional na janela, com a contagem de participantes vivos (para a turma
  # cheia). `authorize?: false` como o resto do motor de disponibilidade — a prévia já está sob a
  # policy da ação de leitura do pacote, e o recorte por profissional é explícito aqui.
  defp existing_blocks(scope, professional_id, from, to, tz) do
    {:ok, from_dt} = LocalTime.to_utc(from, "00:00", tz)
    {:ok, to_dt} = LocalTime.to_utc(Date.add(to, 1), "00:00", tz)

    Api.Scheduling.list_appointments!(from_dt, to_dt,
      scope: scope,
      query: [filter: [professional_id: professional_id]],
      load: [:attendances]
    )
    |> Enum.map(fn appt ->
      %{
        starts_at: appt.starts_at,
        ends_at: appt.ends_at,
        status: appt.status,
        appointment_type_id: appt.appointment_type_id,
        participantes: Enum.count(appt.attendances, &(&1.status != :cancelada))
      }
    end)
  end
end
