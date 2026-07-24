defmodule Api.Waitlist.ConvertTest do
  @moduledoc """
  A conversão de um item da fila em agendamento (doc 25, Entrega 5 / doc 09 §6.2).

  **Não há reserva de vaga** (doc 39): a corrida entre dois atendentes é resolvida pela exclusion
  constraint do **agendamento** — o segundo a confirmar leva `schedule_conflict` e escolhe outro
  horário. A garantia sob concorrência real (duas conexões) é propriedade da constraint, e é
  verificada por `psql`/bate-volta, não pelo sandbox.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling
  alias Api.Waitlist

  @segunda ~D[2026-07-20]

  defp email, do: "oc-#{System.unique_integer([:positive])}@example.com"

  defp setup_clinic do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    scope = scope_for(owner, clinic)
    prof = Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)

    tipo =
      Directory.create_appointment_type!(
        %{
          nome: "Sessão #{System.unique_integer([:positive])}",
          duracao_minutos: 50,
          cor: "#0FB5A6",
          icon: "Activity"
        },
        tenant: clinic.id,
        actor: owner
      )

    p = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)
    {:ok, entry} = Waitlist.enqueue_entry(scope, %{patient_id: p.id})

    %{
      owner: owner,
      clinic: clinic,
      scope: scope,
      prof: prof,
      tipo: tipo,
      patient: p,
      entry: entry
    }
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  defp member_scope(clinic, papel) do
    user = Accounts.register_user!("Membro #{papel}", email(), authorize?: false)

    {:ok, m} =
      Accounts.invite_member(%{papel: papel, user_id: user.id, clinic_id: clinic.id},
        authorize?: false
      )

    {:ok, _} = Accounts.accept_invite(m, authorize?: false)
    scope_for(user, clinic)
  end

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  describe "convert" do
    test "cria o agendamento do paciente do item e o tira da fila" do
      ctx = setup_clinic()

      assert {:ok, appt} =
               Waitlist.convert(ctx.scope, ctx.entry, %{
                 starts_at: at("09:00"),
                 professional_id: ctx.prof.id,
                 appointment_type_id: ctx.tipo.id,
                 encaixe: false
               })

      assert appt.professional_id == ctx.prof.id
      appt = Scheduling.get_appointment!(appt.id, scope: ctx.scope, load: [:attendances])
      assert [%{patient_id: pid}] = appt.attendances
      assert pid == ctx.patient.id

      assert %{entries: []} = Waitlist.list_entries(ctx.scope)
    end

    test "funciona sem oferta prévia (agendar manualmente)" do
      ctx = setup_clinic()

      assert {:ok, _appt} =
               Waitlist.convert(ctx.scope, ctx.entry, %{
                 starts_at: at("10:00"),
                 professional_id: ctx.prof.id,
                 appointment_type_id: ctx.tipo.id
               })
    end

    test "horário já tomado → propaga o conflito e mantém o item na fila" do
      ctx = setup_clinic()
      outro = Records.create_patient!("Outro", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      {:ok, _} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("09:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [outro.id]
          },
          scope: ctx.scope
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Waitlist.convert(ctx.scope, ctx.entry, %{
                 starts_at: at("09:00"),
                 professional_id: ctx.prof.id,
                 appointment_type_id: ctx.tipo.id
               })

      # O item continua na fila (a conversão falhou antes de remover).
      assert %{entries: [_]} = Waitlist.list_entries(ctx.scope)
    end
  end
end
