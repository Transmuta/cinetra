# Seed de VOLUME (D-S — docs 30/35). Popula uma clínica dedicada com ~10k agendamentos para
# tornar mensuráveis as dívidas de performance de leitura (D-A `:in_range`, D-D availability,
# D-R pool). NÃO é o seed de demonstração — é dado de carga, isolado num tenant próprio.
#
#   MIX_ENV=dev DATABASE_HOST=localhost DATABASE_PORT=5434 mix run priv/repo/volume_seed.exs
#
# Idempotente: se a clínica de volume já existe, não faz nada (rode à vontade).
#
# Os agendamentos entram por `Ash.Seed.seed!` (insere direto no data layer), de propósito: as
# ações normais dispariam o notifier (dilúvio de PubSub + linhas de notificação), gravariam uma
# versão de paper-trail por linha e rodariam a checagem de disponibilidade — 10k vezes. Nada
# disso é necessário para dar VOLUME de leitura, e tornaria o seed lento e sujo. Os "pais"
# (clínica, profissionais, pacientes) são poucos e nascem pelas ações de verdade.

require Ash.Query

alias Api.Accounts
alias Api.Directory
alias Api.Records
alias Api.Scheduling.{Appointment, Attendance, LocalTime}

clinic_name = "Clínica Volume (perf) — seed D-S"
tz = "America/Sao_Paulo"
n_professionals = 15
n_patients = 200
# Slots horários (pula o almoço às 12): 7 por profissional por dia, sempre distintos → nunca
# sobrepõem, então a exclusion constraint `appointments_no_overlap` nunca dispara.
slot_hours = [8, 9, 10, 11, 13, 14, 15]
duration_min = 50
# Janela de ~135 dias corridos (~96 dias úteis) em torno de hoje: passado E futuro, para
# exercitar tanto a leitura de histórico quanto a agenda futura.
today = Date.utc_today()
date_from = Date.add(today, -70)
date_to = Date.add(today, 65)

# Determinístico: o seed roda uma vez, mas se rodar de novo (outro banco) sai igual.
:rand.seed(:exsss, {101, 202, 303})

# ---- Idempotência ---------------------------------------------------------------------------
existing =
  Api.Accounts.Clinic
  |> Ash.Query.filter(nome == ^clinic_name)
  |> Ash.read!(authorize?: false)

if existing != [] do
  clinic = hd(existing)

  count =
    Appointment
    |> Ash.Query.filter(clinic_id == ^clinic.id)
    |> Ash.count!(authorize?: false, tenant: clinic.id)

  IO.puts("• Seed de volume já existe (clínica #{clinic.id}, #{count} agendamentos). Nada a fazer.")
else
  IO.puts("• Criando a clínica de volume e a equipe…")

  owner =
    Accounts.register_user!(
      "Dono Volume",
      "volume-owner-#{System.unique_integer([:positive])}@seed.local",
      authorize?: false
    )

  clinic = Accounts.onboard_clinic!(clinic_name, %{}, actor: owner)

  professionals =
    for i <- 1..n_professionals do
      Directory.create_professional!("Prof. Volume #{i}", %{}, tenant: clinic.id, actor: owner)
    end

  patients =
    for i <- 1..n_patients do
      Records.create_patient!("Paciente Volume #{i}", %{}, tenant: clinic.id, actor: owner)
    end

  # `list_appointment_types!` já exclui arquivados (T2). O onboard semeia os 5 tipos padrão.
  types = Directory.list_appointment_types!(tenant: clinic.id, actor: owner)
  types = if types == [], do: raise("nenhum tipo de atendimento no onboard"), else: types

  IO.puts(
    "  #{length(professionals)} profissionais, #{length(patients)} pacientes, #{length(types)} tipos."
  )

  # ---- Dias úteis da janela -----------------------------------------------------------------
  business_days =
    date_from
    |> Date.range(date_to)
    |> Enum.filter(&(Date.day_of_week(&1) in 1..5))

  utc! = fn date, hour ->
    {:ok, dt} = LocalTime.to_utc(date, "#{String.pad_leading("#{hour}", 2, "0")}:00", tz)
    dt
  end

  # Status coerente com a data: passado majoritariamente concluído (com faltas e alguns
  # cancelados), futuro agendado/confirmado. O `att_status` da presença espelha o do bloco.
  status_for = fn date ->
    if Date.compare(date, today) == :lt do
      case :rand.uniform(100) do
        n when n <= 70 -> {:concluido, :concluida}
        n when n <= 90 -> {:faltou, :faltou}
        _ -> {:cancelado, :cancelada}
      end
    else
      if(:rand.uniform(100) <= 60, do: {:agendado, :prevista}, else: {:confirmado, :prevista})
    end
  end

  # ---- Especificações (um mapa por agendamento) ---------------------------------------------
  specs =
    for date <- business_days,
        {prof, pidx} <- Enum.with_index(professionals),
        {hour, hidx} <- Enum.with_index(slot_hours) do
      starts = utc!.(date, hour)
      ends = DateTime.add(starts, duration_min * 60, :second)
      {appt_status, att_status} = status_for.(date)
      type = Enum.at(types, rem(pidx + hidx, length(types)))
      patient = Enum.at(patients, :rand.uniform(n_patients) - 1)

      %{
        appt: %{
          starts_at: starts,
          ends_at: ends,
          professional_id: prof.id,
          appointment_type_id: type.id,
          status: appt_status,
          encaixe: false,
          version: 1,
          pkg_hold: false,
          created_by_id: owner.id
        },
        patient_id: patient.id,
        att_status: att_status
      }
    end

  IO.puts("• Inserindo #{length(specs)} agendamentos (Ash.Seed, em lotes)…")

  # Lotes para limitar transação/memória; a ordem de retorno espelha a de entrada, então dá
  # para casar cada agendamento criado com a presença que ele deve receber.
  created =
    specs
    |> Enum.chunk_every(1000)
    |> Enum.flat_map(fn chunk ->
      appts = Ash.Seed.seed!(Appointment, Enum.map(chunk, & &1.appt), tenant: clinic.id)

      att_input =
        Enum.zip(appts, chunk)
        |> Enum.map(fn {appt, spec} ->
          %{
            appointment_id: appt.id,
            patient_id: spec.patient_id,
            status: spec.att_status,
            falta_justificada: false
          }
        end)

      _ = Ash.Seed.seed!(Attendance, att_input, tenant: clinic.id)
      IO.write(".")
      appts
    end)

  IO.puts("\n✓ Pronto: #{length(created)} agendamentos + presenças na clínica #{clinic.id}.")
end
