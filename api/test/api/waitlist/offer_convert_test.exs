defmodule Api.Waitlist.OfferConvertTest do
  @moduledoc """
  A oferta de vaga (`SlotHold`) e a conversão em agendamento (doc 25, Entrega 5 / doc 09 §6.2).

  A corrida aqui é **síncrona** (duas ofertas na mesma conexão): a segunda bate na exclusion
  constraint e vira `{:slot_held, meta}`. A garantia sob **concorrência real** (duas conexões) é
  propriedade da constraint e é verificada por `psql`/bate-volta, não pelo sandbox.
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

  describe "offer_slot" do
    test "segura a vaga e devolve o hold" do
      ctx = setup_clinic()

      assert {:ok, hold} =
               Waitlist.offer_slot(ctx.scope, ctx.entry, %{
                 professional_id: ctx.prof.id,
                 starts_at: at("09:00"),
                 duration_minutos: 50
               })

      assert hold.professional_id == ctx.prof.id
      assert hold.held_by_id == ctx.owner.id
    end

    test "vaga já segurada por outro → {:slot_held, meta} com quem segura e até quando" do
      ctx = setup_clinic()
      # O dono segura 09:00–09:50.
      {:ok, _} =
        Waitlist.offer_slot(ctx.scope, ctx.entry, %{
          professional_id: ctx.prof.id,
          starts_at: at("09:00")
        })

      # A recepção tenta um horário sobreposto do mesmo profissional.
      recepcao = member_scope(ctx.clinic, :recepcao)

      assert {:error, {:slot_held, meta}} =
               Waitlist.offer_slot(recepcao, ctx.entry, %{
                 professional_id: ctx.prof.id,
                 starts_at: at("09:30")
               })

      assert meta.held_by.nome == "Dono"
      assert %DateTime{} = meta.expires_at
    end

    test "liberada a vaga, a oferta seguinte passa" do
      ctx = setup_clinic()

      {:ok, hold} =
        Waitlist.offer_slot(ctx.scope, ctx.entry, %{
          professional_id: ctx.prof.id,
          starts_at: at("09:00")
        })

      :ok = Scheduling.release_slot_hold(hold, scope: ctx.scope)

      assert {:ok, _} =
               Waitlist.offer_slot(ctx.scope, ctx.entry, %{
                 professional_id: ctx.prof.id,
                 starts_at: at("09:30")
               })
    end

    # Bate-volta E5 (segurança): a constraint `slot_holds_no_overlap` é GLOBAL (ADR-017), então
    # segurar vaga de um profissional de OUTRA clínica seria um vetor cross-tenant (negar por
    # 10 min a reserva alheia). O `professional_id` tem de ser da clínica ativa.
    test "offer com profissional de outra clínica é recusado (não cruza o tenant)" do
      ctx = setup_clinic()
      other_owner = Accounts.register_user!("Dono2", email(), authorize?: false)

      other =
        Accounts.onboard_clinic!("Outra #{System.unique_integer([:positive])}", %{},
          actor: other_owner
        )

      alheio =
        Directory.create_professional!("Dra. Alheia", %{}, tenant: other.id, actor: other_owner)

      assert {:error, %Ash.Error.Invalid{}} =
               Waitlist.offer_slot(ctx.scope, ctx.entry, %{
                 professional_id: alheio.id,
                 starts_at: at("09:00")
               })
    end
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
