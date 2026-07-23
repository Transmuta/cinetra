defmodule Api.Scheduling.SummaryTest do
  @moduledoc """
  O snapshot de métricas da tela de Relatórios (doc 33, Fatia 9): `Scheduling.load_summary/5` —
  totais por status, taxa de falta, ocupação canônica (minutos ÷ expediente real, GAP-11) e as
  quebras por dia/tipo/profissional, com o recorte por papel (§3) vindo de `OwnAgendaOnly`.

  Como em `AuditLogTest`, a RLS não é exercida aqui (o sandbox conecta como `postgres`,
  BYPASSRLS); o recorte de papel testado é o **de dados** (quais linhas), não o da GUC.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling

  # Segunda e terça de uma semana comum (clínica aberta 08–12 / 13–18 = 540 min/dia no seed).
  @segunda ~D[2026-07-20]
  @terca ~D[2026-07-21]
  @tz "America/Sao_Paulo"

  defp email, do: "summary-#{System.unique_integer([:positive])}@example.com"

  defp setup_clinic do
    owner = Accounts.register_user!("Dona Ana", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    scope = scope_for(owner, clinic)
    prof = Directory.create_professional!("Dra. Bea", %{}, tenant: clinic.id, actor: owner)
    tipo = create_tipo(clinic, owner, "Fisio")
    paciente = Records.create_patient!("Caio Paciente", %{}, tenant: clinic.id, actor: owner)

    %{owner: owner, clinic: clinic, scope: scope, prof: prof, tipo: tipo, paciente: paciente}
  end

  defp create_tipo(clinic, owner, nome) do
    Directory.create_appointment_type!(
      %{
        nome: "#{nome} #{System.unique_integer([:positive])}",
        duracao_minutos: 50,
        cor: "#0FB5A6",
        icon: "Activity"
      },
      tenant: clinic.id,
      actor: owner
    )
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  # Um membro `profissional` vinculado (ou não) a um professional_id, e o escopo dele.
  defp profissional_scope(clinic, professional_id) do
    user = Accounts.register_user!("Membro prof", email(), authorize?: false)
    attrs = %{papel: :profissional, user_id: user.id, clinic_id: clinic.id}
    attrs = if professional_id, do: Map.put(attrs, :professional_id, professional_id), else: attrs
    {:ok, m} = Accounts.invite_member(attrs, authorize?: false)
    {:ok, _} = Accounts.accept_invite(m, authorize?: false)
    scope_for(user, clinic)
  end

  defp at(date, hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(date, hhmm, @tz)
    dt
  end

  defp schedule(ctx, date, hhmm, attrs \\ %{}) do
    base = %{
      starts_at: at(date, hhmm),
      professional_id: ctx.prof.id,
      appointment_type_id: ctx.tipo.id,
      patient_ids: [ctx.paciente.id]
    }

    {:ok, appt} = Scheduling.schedule_appointment(Map.merge(base, attrs), scope: ctx.scope)
    appt
  end

  defp transition(ctx, appt, kind) do
    {:ok, updated} = Scheduling.transition_appointment(ctx.scope, appt.id, kind)
    updated
  end

  defp summary(ctx, from, to, professional_id \\ nil, scope \\ nil) do
    Scheduling.load_summary(scope || ctx.scope, from, to, professional_id, @tz)
  end

  describe "totais, taxa de falta e ocupação canônica" do
    test "agrega status na janela de um dia" do
      ctx = setup_clinic()
      transition(ctx, schedule(ctx, @segunda, "08:00"), :complete)
      transition(ctx, schedule(ctx, @segunda, "09:00"), :complete)
      transition(ctx, schedule(ctx, @segunda, "10:00"), :miss)
      schedule(ctx, @segunda, "11:00")
      transition(ctx, schedule(ctx, @segunda, "13:00"), :cancel)

      t = summary(ctx, @segunda, @segunda).totais

      # Ativos = não-cancelado: 2 concluídos + 1 falta + 1 agendado.
      assert t.atendimentos == 4
      assert t.concluidos == 2
      assert t.faltas == 1
      assert t.cancelados == 1
      assert t.futuros == 1
      # falta / (concluídos + falta) = 1/3 ≈ 33%.
      assert t.taxa_falta == 33
    end

    test "ocupação é minutos agendados ÷ expediente real (não os 9 slots), cancelado fora" do
      ctx = setup_clinic()
      transition(ctx, schedule(ctx, @segunda, "08:00"), :complete)
      schedule(ctx, @segunda, "09:00")
      # Um cancelado NÃO entra nem no numerador nem em atendimentos.
      transition(ctx, schedule(ctx, @segunda, "10:00"), :cancel)

      t = summary(ctx, @segunda, @segunda).totais

      # Dois ativos × 50 min = 100 min agendados; cancelado não conta.
      assert t.ocupado_minutos == 100
      # Segunda no seed: 08–12 + 13–18 = 540 min de expediente, um profissional.
      assert t.capacidade_minutos == 540
      assert t.ocupacao == round(100 / 540 * 100)
      assert t.dias_uteis == 1
    end

    test "denominador zero da taxa de falta (só futuros) é 0%, não erro" do
      ctx = setup_clinic()
      schedule(ctx, @segunda, "08:00")
      schedule(ctx, @segunda, "09:00")

      t = summary(ctx, @segunda, @segunda).totais

      assert t.concluidos == 0
      assert t.faltas == 0
      assert t.taxa_falta == 0
      assert t.futuros == 2
    end
  end

  describe "quebras por dia, tipo e profissional" do
    test "por_dia cobre toda a janela e o pico é o dia mais movimentado" do
      ctx = setup_clinic()
      schedule(ctx, @segunda, "08:00")
      schedule(ctx, @segunda, "09:00")
      schedule(ctx, @terca, "08:00")

      r = summary(ctx, @segunda, @terca)

      assert Enum.map(r.por_dia, & &1.date) == [@segunda, @terca]
      assert Enum.map(r.por_dia, & &1.total) == [2, 1]
      assert r.totais.pico == %{date: @segunda, total: 2}
      assert r.totais.dias_uteis == 2
    end

    test "por_tipo conta os ativos por tipo, em ordem decrescente" do
      ctx = setup_clinic()
      outro = create_tipo(ctx.clinic, ctx.owner, "Pilates")

      schedule(ctx, @segunda, "08:00")
      schedule(ctx, @segunda, "09:00")
      schedule(ctx, @segunda, "10:00", %{appointment_type_id: outro.id})

      por_tipo = summary(ctx, @segunda, @segunda).por_tipo

      assert [%{appointment_type_id: t1, total: 2}, %{appointment_type_id: t2, total: 1}] =
               por_tipo

      assert t1 == ctx.tipo.id
      assert t2 == outro.id
    end

    test "por_profissional traz total/concluídos/faltas/taxa por profissional" do
      ctx = setup_clinic()

      bruno =
        Directory.create_professional!("Dr. Bruno", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      transition(ctx, schedule(ctx, @segunda, "08:00"), :complete)
      transition(ctx, schedule(ctx, @segunda, "09:00"), :miss)
      schedule(ctx, @segunda, "10:00", %{professional_id: bruno.id})

      por_prof = summary(ctx, @segunda, @segunda).por_profissional
      bea = Enum.find(por_prof, &(&1.professional_id == ctx.prof.id))
      bru = Enum.find(por_prof, &(&1.professional_id == bruno.id))

      assert bea.total == 2 and bea.concluidos == 1 and bea.faltas == 1 and bea.taxa_falta == 50
      assert bru.total == 1 and bru.concluidos == 0 and bru.faltas == 0
      # Bea (2) vem antes de Bruno (1): ordenação decrescente por volume.
      assert Enum.map(por_prof, & &1.professional_id) == [ctx.prof.id, bruno.id]
    end
  end

  describe "escopo por papel (doc 33 §3)" do
    test "profissional vê só os próprios números" do
      ctx = setup_clinic()

      bruno =
        Directory.create_professional!("Dr. Bruno", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      schedule(ctx, @segunda, "08:00")
      schedule(ctx, @segunda, "09:00")
      schedule(ctx, @segunda, "10:00", %{professional_id: bruno.id})

      escopo = profissional_scope(ctx.clinic, ctx.prof.id)
      r = summary(ctx, @segunda, @segunda, nil, escopo)

      # Só os dois da Bea; o de Bruno some, e a quebra tem uma linha só.
      assert r.totais.atendimentos == 2
      assert Enum.map(r.por_profissional, & &1.professional_id) == [ctx.prof.id]
      assert Enum.map(r.professionals, & &1.id) == [ctx.prof.id]
    end

    test "owner filtrando professional_id recorta ao escolhido" do
      ctx = setup_clinic()

      bruno =
        Directory.create_professional!("Dr. Bruno", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      schedule(ctx, @segunda, "08:00")
      schedule(ctx, @segunda, "10:00", %{professional_id: bruno.id})

      r = summary(ctx, @segunda, @segunda, bruno.id)

      assert r.totais.atendimentos == 1
      assert Enum.map(r.por_profissional, & &1.professional_id) == [bruno.id]
    end

    test "profissional sem vínculo recebe relatório zerado (fail-closed)" do
      ctx = setup_clinic()
      schedule(ctx, @segunda, "08:00")

      escopo = profissional_scope(ctx.clinic, nil)
      r = summary(ctx, @segunda, @segunda, nil, escopo)

      assert r.totais.atendimentos == 0
      assert r.totais.capacidade_minutos == 0
      assert r.por_profissional == []
      assert r.professionals == []
    end
  end
end
