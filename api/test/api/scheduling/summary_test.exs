defmodule Api.Scheduling.SummaryTest do
  @moduledoc """
  O snapshot de métricas da tela de Relatórios (doc 33, Fatia 9): `Scheduling.load_summary/5` —
  totais por status, taxa de falta, ocupação canônica (minutos ÷ expediente real, GAP-11) e as
  quebras por dia/tipo/profissional, com o recorte por papel (§3) vindo de `OwnAgendaOnly`.

  Como em `AuditLogTest`, a RLS não é exercida aqui (o sandbox conecta como `postgres`,
  BYPASSRLS); o recorte de papel testado é o **de dados** (quais linhas), não o da GUC.
  """
  use Api.DataCase, async: false

  alias Api.Scheduling

  # Segunda e terça de uma semana comum (clínica aberta 08–12 / 13–18 = 540 min/dia no seed).
  @segunda ~D[2026-07-20]
  @terca ~D[2026-07-21]
  @tz "America/Sao_Paulo"

  defp setup_clinic,
    do:
      clinica(
        dono: "Dona Ana",
        prof: "Dra. Bea",
        paciente: "Caio Paciente",
        tipo: [nome: "Fisio #{unico()}"]
      )

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

  # O DESFECHO é da presença (A2, doc 41) — o relatório lê o status do bloco, que é o rollup dela.
  # Cancelar continua sendo do bloco: é fase de agendamento, não desfecho.
  defp transition(ctx, appt, kind) when kind in [:complete, :no_show] do
    att =
      Scheduling.list_attendances!(scope: ctx.scope, query: [filter: [appointment_id: appt.id]])
      |> hd()

    {:ok, updated} = Scheduling.transition_participant(ctx.scope, appt.id, att.patient_id, kind)
    updated
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
      transition(ctx, schedule(ctx, @segunda, "10:00"), :no_show)
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

    # A-1 do doc 88, achado do QA guiado: numa TURMA o desfecho do bloco é o rollup das presenças
    # ("alguma concluída ⇒ bloco concluído"), então contar `appointment.status` some com a falta de
    # quem não veio. Uma turma de 2 com 1 presente e 1 falta aparecia como "1 concluído, 0 faltas";
    # uma de 4 em que os 4 faltaram contava 1 falta, não 4.
    #
    # A régua do relatório passou a ser a PRESENÇA (quem foi atendido), não o bloco. Para
    # atendimento individual os dois números coincidem — por isso o desvio nunca apareceu.
    test "turma: conta PRESENÇA, não bloco (1 presente + 1 falta = 1 e 1)" do
      ctx = setup_clinic()
      turma = tipo!(ctx, nome: "Pilates #{unico()}", grupo: true, capacidade: 4)
      outro = paciente!(ctx, "Segundo Paciente")

      appt =
        schedule(ctx, @segunda, "08:00", %{
          appointment_type_id: turma.id,
          patient_ids: [ctx.paciente.id, outro.id]
        })

      {:ok, _} = Scheduling.transition_participant(ctx.scope, appt.id, ctx.paciente.id, :complete)
      {:ok, _} = Scheduling.transition_participant(ctx.scope, appt.id, outro.id, :no_show)

      t = summary(ctx, @segunda, @segunda).totais

      # O bloco é UM e seu status é `:concluido` — mas duas pessoas foram atendidas, e uma faltou.
      assert t.atendimentos == 2
      assert t.concluidos == 1
      assert t.faltas == 1
      assert t.taxa_falta == 50

      # A ocupação continua sendo do BLOCO: a turma ocupa um slot, tenham vindo 1 ou 4.
      assert t.ocupado_minutos == 50
    end

    test "turma em que TODOS faltaram conta cada falta, não uma" do
      ctx = setup_clinic()
      turma = tipo!(ctx, nome: "Pilates #{unico()}", grupo: true, capacidade: 4)
      outro = paciente!(ctx, "Segundo Paciente")

      appt =
        schedule(ctx, @segunda, "08:00", %{
          appointment_type_id: turma.id,
          patient_ids: [ctx.paciente.id, outro.id]
        })

      {:ok, _} = Scheduling.transition_participant(ctx.scope, appt.id, ctx.paciente.id, :no_show)
      {:ok, _} = Scheduling.transition_participant(ctx.scope, appt.id, outro.id, :no_show)

      t = summary(ctx, @segunda, @segunda).totais

      assert t.faltas == 2
      assert t.concluidos == 0
      assert t.taxa_falta == 100
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
      outro = tipo!(ctx, nome: "Pilates #{unico()}")

      schedule(ctx, @segunda, "08:00")
      schedule(ctx, @segunda, "09:00")
      schedule(ctx, @segunda, "10:00", %{appointment_type_id: outro.id})

      por_tipo = summary(ctx, @segunda, @segunda).por_tipo

      assert [%{appointment_type_id: t1, total: 2}, %{appointment_type_id: t2, total: 1}] =
               por_tipo

      assert t1 == ctx.tipo.id
      assert t2 == outro.id
    end

    # Mesmo A-1 do doc 88, na quebra que ficou para trás. As outras três quebras passaram a contar
    # PRESENÇA; `por_tipo` seguiu contando BLOCO, e a divergência é visível na própria tela: o card
    # divide `row.total` por `totais.atendimentos` para mostrar a porcentagem, então uma turma de
    # quatro aparece como "1 (25%)" embaixo de um KPI que diz 4.
    #
    # A invariante que fecha o assunto é a soma: as quebras do mesmo relatório têm de somar o mesmo
    # total, senão uma delas está medindo outra coisa.
    test "por_tipo conta PRESENÇA, não bloco — e soma o mesmo que os totais" do
      ctx = setup_clinic()
      turma = tipo!(ctx, nome: "Pilates #{unico()}", grupo: true, capacidade: 4)
      outro = paciente!(ctx, "Segundo Paciente")

      # Uma turma com DOIS participantes (1 bloco, 2 presenças)...
      schedule(ctx, @segunda, "08:00", %{
        appointment_type_id: turma.id,
        patient_ids: [ctx.paciente.id, outro.id]
      })

      # ...e um atendimento individual (1 bloco, 1 presença).
      schedule(ctx, @segunda, "09:00")

      r = summary(ctx, @segunda, @segunda)

      assert r.totais.atendimentos == 3

      assert Enum.sum(Enum.map(r.por_tipo, & &1.total)) == r.totais.atendimentos,
             "por_tipo soma #{Enum.sum(Enum.map(r.por_tipo, & &1.total))} " <>
               "mas os totais dizem #{r.totais.atendimentos} — unidades diferentes"

      # A turma (2 pessoas) vem na frente do individual (1), que é a ordenação por volume real.
      assert [%{appointment_type_id: t1, total: 2}, %{appointment_type_id: t2, total: 1}] =
               r.por_tipo

      assert t1 == turma.id
      assert t2 == ctx.tipo.id
    end

    # A presença `:cancelada` é o participante que saiu da turma — não foi atendido nem faltou, e
    # sai da conta como já sai das outras três quebras (`summary_presencas/1`).
    test "por_tipo ignora a presença cancelada, como as outras quebras" do
      ctx = setup_clinic()
      turma = tipo!(ctx, nome: "Pilates #{unico()}", grupo: true, capacidade: 4)
      outro = paciente!(ctx, "Segundo Paciente")

      appt =
        schedule(ctx, @segunda, "08:00", %{
          appointment_type_id: turma.id,
          patient_ids: [ctx.paciente.id, outro.id]
        })

      {:ok, _} =
        Scheduling.remove_appointment_participants(appt, %{patient_ids: [outro.id]},
          scope: ctx.scope
        )

      r = summary(ctx, @segunda, @segunda)
      turma_id = turma.id

      assert [%{appointment_type_id: ^turma_id, total: 1}] = r.por_tipo
      assert r.totais.atendimentos == 1
    end

    test "por_profissional traz total/concluídos/faltas/taxa por profissional" do
      ctx = setup_clinic()

      bruno =
        profissional!(ctx, "Dr. Bruno")

      transition(ctx, schedule(ctx, @segunda, "08:00"), :complete)
      transition(ctx, schedule(ctx, @segunda, "09:00"), :no_show)
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
        profissional!(ctx, "Dr. Bruno")

      schedule(ctx, @segunda, "08:00")
      schedule(ctx, @segunda, "09:00")
      schedule(ctx, @segunda, "10:00", %{professional_id: bruno.id})

      escopo = escopo_de_membro!(ctx, :profissional, ctx.prof.id)
      r = summary(ctx, @segunda, @segunda, nil, escopo)

      # Só os dois da Bea; o de Bruno some, e a quebra tem uma linha só.
      assert r.totais.atendimentos == 2
      assert Enum.map(r.por_profissional, & &1.professional_id) == [ctx.prof.id]
      assert Enum.map(r.professionals, & &1.id) == [ctx.prof.id]
    end

    test "owner filtrando professional_id recorta ao escolhido" do
      ctx = setup_clinic()

      bruno =
        profissional!(ctx, "Dr. Bruno")

      schedule(ctx, @segunda, "08:00")
      schedule(ctx, @segunda, "10:00", %{professional_id: bruno.id})

      r = summary(ctx, @segunda, @segunda, bruno.id)

      assert r.totais.atendimentos == 1
      assert Enum.map(r.por_profissional, & &1.professional_id) == [bruno.id]
    end

    test "profissional sem vínculo recebe relatório zerado (fail-closed)" do
      ctx = setup_clinic()
      schedule(ctx, @segunda, "08:00")

      escopo = escopo_de_membro!(ctx, :profissional, nil)
      r = summary(ctx, @segunda, @segunda, nil, escopo)

      assert r.totais.atendimentos == 0
      assert r.totais.capacidade_minutos == 0
      assert r.por_profissional == []
      assert r.professionals == []
    end
  end
end
