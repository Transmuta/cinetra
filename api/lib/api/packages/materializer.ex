defmodule Api.Packages.Materializer do
  @moduledoc """
  Materializa a série de um pacote — o job Oban que cria os N agendamentos reais a partir da grade
  (doc 04 §6, RN-18). Enfileirado por `Api.Packages.create_series/2` na **criação** do pacote, para
  não travar o request: uma série de 40 sessões não pode segurar a resposta HTTP.

  ## O que faz por ocorrência

  Reprojeta a série (mesmo `Api.Packages.Series` da prévia — o calendário pode ter mudado entre a
  prévia e o job) e, para cada ocorrência **não-feriado**, cria a sessão via
  `Api.Scheduling.schedule_appointment/2` (que já funde em turma existente quando é o caso, A-D4) e
  carimba o `package_id` na presença do paciente — o vínculo que o contador `usadas` conta (D11).

  Feriado **não vira sessão**: é marcador de calendário; a série já se estendeu para entregar as N
  úteis (RN-19).

  ## `encaixe` e o que o job NÃO pode forçar

  `forcar` (o "agendar mesmo assim" da tela) vira `encaixe: true` — que fura a exclusion constraint
  (conflito) e o teto de turma (cheia). **Não fura o expediente**: `CheckAvailability` é bloqueio
  absoluto (D14), encaixe não isenta. Por isso `create_series/2` **recusa** de saída uma grade com
  ocorrência fora do expediente — o job nunca recebe uma; se uma surgir por corrida (mudaram o
  expediente entre a criação e o job), a sessão falha e o job registra, sem materializar meia série
  em silêncio.

  ## Idempotência

  Oban re-executa em falha. Antes de materializar, o job lê as presenças já carimbadas com este
  `package_id` e **pula** as ocorrências cujo horário já existe. Uma re-execução após sucesso é
  no-op; após falha parcial, completa o que faltou.
  """
  use Oban.Worker, queue: :housekeeping, max_attempts: 3

  require Logger

  alias Api.Scheduling.LocalTime

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"package_id" => package_id, "clinic_id" => clinic_id} = args
    forcar = Map.get(args, "forcar", false)

    pkg =
      Api.Packages.get_package!(package_id,
        tenant: clinic_id,
        authorize?: false,
        load: [:schedule]
      )

    materialize(pkg, clinic_id, forcar)
  end

  defp materialize(%{schedule: nil} = pkg, _clinic_id, _forcar) do
    # Sem grade não há o que materializar — não deveria acontecer (a grade nasce com o pacote), mas
    # falhar aqui só geraria retry infinito. Registra e encerra.
    Logger.error("Pacote #{pkg.id} sem grade na materialização; nada a fazer")
    :ok
  end

  defp materialize(pkg, clinic_id, forcar) do
    %{timezone: tz} = Api.Scheduling.load_clinic(clinic_id)

    tipo =
      Api.Directory.get_appointment_type!(pkg.appointment_type_id,
        tenant: clinic_id,
        authorize?: false
      )

    feriados = Api.Scheduling.clinic_holidays(clinic_id)

    grade = %{dows: pkg.schedule.dows, horarios: pkg.schedule.horarios}

    with {:ok, ocorrencias} <-
           Api.Packages.Series.project(pkg.data_inicio, grade, pkg.total, feriados) do
      ja_feitas = materialized_starts(pkg.id, clinic_id)

      ocorrencias
      |> Enum.reject(& &1.feriado?)
      |> Enum.each(fn occ ->
        {:ok, starts_at} = LocalTime.to_utc(occ.data, occ.hhmm, tz)

        unless MapSet.member?(ja_feitas, DateTime.to_iso8601(starts_at)) do
          create_session(pkg, tipo, starts_at, clinic_id, forcar)
        end
      end)

      :ok
    end
  end

  defp create_session(pkg, tipo, starts_at, clinic_id, forcar) do
    attrs = %{
      starts_at: starts_at,
      professional_id: pkg.schedule.professional_id,
      appointment_type_id: tipo.id,
      patient_ids: [pkg.patient_id],
      encaixe: forcar
    }

    {:ok, appt} = Api.Scheduling.schedule_appointment(attrs, tenant: clinic_id, authorize?: false)
    stamp_package(appt.id, pkg, clinic_id)
  end

  # Carimba o `package_id` na presença deste paciente na sessão recém-criada (ou recém-fundida).
  defp stamp_package(appointment_id, pkg, clinic_id) do
    appt =
      Api.Scheduling.get_appointment!(appointment_id,
        tenant: clinic_id,
        authorize?: false,
        load: [:attendances]
      )

    att = Enum.find(appt.attendances, &(&1.patient_id == pkg.patient_id))

    Api.Scheduling.set_attendance_package!(att, %{package_id: pkg.id},
      tenant: clinic_id,
      authorize?: false
    )
  end

  # As presenças já carimbadas com este pacote → conjunto dos horários (ISO) já materializados.
  defp materialized_starts(package_id, clinic_id) do
    Api.Scheduling.list_attendances!(
      tenant: clinic_id,
      authorize?: false,
      query: [filter: [package_id: package_id]],
      load: [:appointment]
    )
    |> MapSet.new(&DateTime.to_iso8601(&1.appointment.starts_at))
  end
end
