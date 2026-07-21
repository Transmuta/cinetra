defmodule Api.Notifications.FanoutTest do
  @moduledoc """
  O fan-out por papel (doc 31 §2), exercido pelos eventos de domínio reais que o disparam:

    * ciclo de vida do agendamento → o profissional dono da coluna (menos o autor);
    * falta/cancelamento que abre vaga com fila casando → recepção/admin/owner;
    * convite aceito → owner/admin (menos o recém-chegado).

  Prova as três invariantes: destinatário certo, recorte por papel e **supressão do autor**.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Notifications
  alias Api.Records
  alias Api.Scheduling
  alias Api.Waitlist

  # 2026-07-27 é uma segunda; o seed do onboard abre seg–sex 08–12 / 13–18. SP = UTC-3.
  @segunda ~D[2026-07-27]

  defp email, do: "fan-#{System.unique_integer([:positive])}@example.com"

  defp setup_clinic do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    prof = Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)

    tipo =
      Directory.create_appointment_type!(
        %{nome: "Sessão #{System.unique_integer([:positive])}", duracao_minutos: 50, cor: "#0FB5A6", icon: "Activity"},
        tenant: clinic.id,
        actor: owner
      )

    paciente = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)
    %{owner: owner, clinic: clinic, prof: prof, tipo: tipo, paciente: paciente}
  end

  defp member(clinic, papel, professional_id \\ nil) do
    user = Accounts.register_user!("Membro #{papel}", email(), authorize?: false)
    attrs = %{papel: papel, user_id: user.id, clinic_id: clinic.id}
    attrs = if professional_id, do: Map.put(attrs, :professional_id, professional_id), else: attrs
    {:ok, m} = Accounts.invite_member(attrs, authorize?: false)
    {:ok, _} = Accounts.accept_invite(m, authorize?: false)
    user
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  defp inbox(user, clinic), do: Notifications.list_inbox(scope_for(user, clinic))

  defp kinds(user, clinic), do: inbox(user, clinic) |> Enum.map(& &1.kind)

  defp schedule(ctx, scope, attrs \\ %{}) do
    base = %{
      starts_at: at("08:00"),
      professional_id: ctx.prof.id,
      appointment_type_id: ctx.tipo.id,
      patient_ids: [ctx.paciente.id]
    }

    Scheduling.schedule_appointment(Map.merge(base, attrs), scope: scope)
  end

  describe "ciclo de vida → profissional dono da coluna" do
    test "agendar por outra pessoa notifica o profissional" do
      ctx = setup_clinic()
      prof_user = member(ctx.clinic, :profissional, ctx.prof.id)

      {:ok, _appt} = schedule(ctx, scope_for(ctx.owner, ctx.clinic))

      assert :appointment_scheduled in kinds(prof_user, ctx.clinic)
    end

    test "o autor não se notifica (o próprio profissional agendando)" do
      ctx = setup_clinic()
      prof_user = member(ctx.clinic, :profissional, ctx.prof.id)

      {:ok, _appt} = schedule(ctx, scope_for(prof_user, ctx.clinic))

      refute :appointment_scheduled in kinds(prof_user, ctx.clinic)
    end

    test "remarcar e cancelar também notificam o profissional" do
      ctx = setup_clinic()
      prof_user = member(ctx.clinic, :profissional, ctx.prof.id)
      owner_scope = scope_for(ctx.owner, ctx.clinic)

      {:ok, appt} = schedule(ctx, owner_scope)
      {:ok, _} = Scheduling.transition_appointment(owner_scope, appt.id, :reschedule, %{starts_at: at("09:00")})
      {:ok, appt} = Scheduling.transition_appointment(owner_scope, appt.id, :cancel)
      refute is_nil(appt)

      kinds = kinds(prof_user, ctx.clinic)
      assert :appointment_rescheduled in kinds
      assert :appointment_canceled in kinds
    end

    test "profissional sem usuário vinculado não gera notificação (nem erro)" do
      ctx = setup_clinic()
      # Ninguém vinculado ao ctx.prof — agendar não deve estourar.
      assert {:ok, _appt} = schedule(ctx, scope_for(ctx.owner, ctx.clinic))
    end
  end

  describe "vaga que abre com fila casando → recepção" do
    test "cancelar com fila que casa avisa a recepção" do
      ctx = setup_clinic()
      recep = member(ctx.clinic, :recepcao)
      owner_scope = scope_for(ctx.owner, ctx.clinic)

      # Item de fila que encaixa em qualquer horário (janela :qualquer, sem regras, sem preferido).
      {:ok, _entry} =
        Waitlist.enqueue_entry(owner_scope, %{
          patient_id: Records.create_patient!("Fila", %{}, tenant: ctx.clinic.id, actor: ctx.owner).id,
          prio: :urgente,
          janela: :qualquer,
          professional_ids: [],
          rules: []
        })

      {:ok, appt} = schedule(ctx, owner_scope)
      {:ok, _} = Scheduling.transition_appointment(owner_scope, appt.id, :cancel)

      assert :slot_opened in kinds(recep, ctx.clinic)
    end

    test "sem fila casando, cancelar não gera slot_opened" do
      ctx = setup_clinic()
      recep = member(ctx.clinic, :recepcao)
      owner_scope = scope_for(ctx.owner, ctx.clinic)

      {:ok, appt} = schedule(ctx, owner_scope)
      {:ok, _} = Scheduling.transition_appointment(owner_scope, appt.id, :cancel)

      refute :slot_opened in kinds(recep, ctx.clinic)
    end
  end

  describe "convite aceito → owner/admin" do
    test "o owner é avisado quando um convidado entra" do
      ctx = setup_clinic()
      novo = member(ctx.clinic, :recepcao)

      kinds = kinds(ctx.owner, ctx.clinic)
      assert :member_joined in kinds
      # O recém-chegado não recebe o próprio aviso.
      refute :member_joined in kinds(novo, ctx.clinic)
    end
  end
end
