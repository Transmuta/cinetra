# Sonda do bate-volta: cria UM agendamento na Clínica Agenda Demo (quinta 23/07 às 10h local),
# para observar o que o canal faz no modo `signal`.
user = Api.Accounts.get_user!("019f7c5b-1bb8-79ac-8966-fe5697f777ef", authorize?: false)

{:ok, m} =
  Api.Accounts.get_active_membership(user.id, "019f7c5b-1bee-7a32-9fad-c3d6f0a83177",
    authorize?: false
  )

scope = Api.Scope.with_membership(user, m)

{:ok, appt} =
  Api.Scheduling.schedule_appointment(
    %{
      starts_at: ~U[2026-07-23 13:00:00Z],
      professional_id: "019f7c5b-1ccf-77fd-831f-0ed91406054f",
      appointment_type_id: "019f7c5b-1ca2-71bc-8897-569539e90c83",
      patient_ids: ["019f7c5b-1cee-7ab3-8d81-c421e042c89f"]
    },
    scope: scope
  )

IO.puts("CRIADO #{appt.id}")
