defmodule Api.Scheduling.ParticipantTransitionTest do
  @moduledoc """
  Presença POR PARTICIPANTE (Frente 6/A2, doc 41): `transition_participant/6` marca uma presença
  da turma sem tocar nas outras, e o desfecho do bloco vira rollup. A RLS não é exercida aqui
  (sandbox = `postgres`); o gate `:rls` cobre isso em `rls_smoke_test.exs`.
  """
  use Api.DataCase, async: false

  alias Api.Packages
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp setup_clinic, do: clinica()

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  defp turma_tipo(ctx),
    do: tipo!(ctx, nome: "Turma #{unico()}", icon: "Users", grupo: true, capacidade: 4)

  defp novo_paciente(ctx), do: paciente!(ctx, "Paciente #{unico()}")

  # Uma turma com dois participantes; devolve {appt, segundo_paciente}.
  defp turma_com_dois(ctx) do
    turma = turma_tipo(ctx)
    p2 = novo_paciente(ctx)

    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: at("08:00"),
          professional_id: ctx.prof.id,
          appointment_type_id: turma.id,
          patient_ids: [ctx.paciente.id, p2.id]
        },
        scope: ctx.scope
      )

    {appt, p2}
  end

  defp att_status(appt, patient_id) do
    Enum.find(appt.attendances, &(&1.patient_id == patient_id)).status
  end

  describe "transição por participante não toca nas outras presenças" do
    test "marcar um presente deixa o outro previsto; bloco parcial mantém a fase" do
      ctx = setup_clinic()
      {appt, p2} = turma_com_dois(ctx)

      assert {:ok, updated} =
               Scheduling.transition_participant(
                 ctx.scope,
                 appt.id,
                 ctx.paciente.id,
                 :complete,
                 %{},
                 appt.version
               )

      assert att_status(updated, ctx.paciente.id) == :concluida
      assert att_status(updated, p2.id) == :prevista
      # parcial → o bloco segue na fase de agendamento (não antecipa desfecho)
      assert updated.status == :agendado
      # mexer numa presença bumpa a versão do bloco (lock otimista)
      assert updated.version == appt.version + 1
    end

    test "um presente e um faltou → bloco :concluido (a sessão aconteceu)" do
      ctx = setup_clinic()
      {appt, p2} = turma_com_dois(ctx)

      {:ok, a1} =
        Scheduling.transition_participant(
          ctx.scope,
          appt.id,
          ctx.paciente.id,
          :complete,
          %{},
          appt.version
        )

      {:ok, a2} =
        Scheduling.transition_participant(ctx.scope, appt.id, p2.id, :no_show, %{}, a1.version)

      assert att_status(a2, ctx.paciente.id) == :concluida
      assert att_status(a2, p2.id) == :faltou
      assert a2.status == :concluido
    end

    test "todos faltaram → bloco :faltou" do
      ctx = setup_clinic()
      {appt, p2} = turma_com_dois(ctx)

      {:ok, a1} =
        Scheduling.transition_participant(
          ctx.scope,
          appt.id,
          ctx.paciente.id,
          :no_show,
          %{},
          appt.version
        )

      {:ok, a2} =
        Scheduling.transition_participant(ctx.scope, appt.id, p2.id, :no_show, %{}, a1.version)

      assert a2.status == :faltou
    end
  end

  describe "reabrir e justificar" do
    test "reabrir uma presença resolvida volta o bloco a :agendado" do
      ctx = setup_clinic()
      {appt, p2} = turma_com_dois(ctx)

      {:ok, a1} =
        Scheduling.transition_participant(
          ctx.scope,
          appt.id,
          ctx.paciente.id,
          :complete,
          %{},
          appt.version
        )

      {:ok, a2} =
        Scheduling.transition_participant(ctx.scope, appt.id, p2.id, :complete, %{}, a1.version)

      assert a2.status == :concluido

      {:ok, a3} =
        Scheduling.transition_participant(
          ctx.scope,
          appt.id,
          ctx.paciente.id,
          :reopen,
          %{},
          a2.version
        )

      assert att_status(a3, ctx.paciente.id) == :prevista
      assert a3.status == :agendado
    end

    test "justificar a falta seta falta_justificada e não mexe no status da presença" do
      ctx = setup_clinic()
      {appt, _p2} = turma_com_dois(ctx)

      {:ok, a1} =
        Scheduling.transition_participant(
          ctx.scope,
          appt.id,
          ctx.paciente.id,
          :no_show,
          %{},
          appt.version
        )

      {:ok, a2} =
        Scheduling.transition_participant(
          ctx.scope,
          appt.id,
          ctx.paciente.id,
          :justify,
          %{justificada: true},
          a1.version
        )

      att = Enum.find(a2.attendances, &(&1.patient_id == ctx.paciente.id))
      assert att.status == :faltou
      assert att.falta_justificada == true
    end
  end

  describe "guards" do
    test "expected_version errado → :version_conflict" do
      ctx = setup_clinic()
      {appt, _p2} = turma_com_dois(ctx)

      assert {:error, :version_conflict} =
               Scheduling.transition_participant(
                 ctx.scope,
                 appt.id,
                 ctx.paciente.id,
                 :complete,
                 %{},
                 appt.version + 9
               )
    end

    test "paciente que não está no bloco → :participant_not_found" do
      ctx = setup_clinic()
      {appt, _p2} = turma_com_dois(ctx)
      estranho = novo_paciente(ctx)

      assert {:error, :participant_not_found} =
               Scheduling.transition_participant(
                 ctx.scope,
                 appt.id,
                 estranho.id,
                 :complete,
                 %{},
                 appt.version
               )
    end

    test "bloco cancelado não recebe presença → :block_not_open (F4, não ressuscita)" do
      ctx = setup_clinic()
      {appt, _p2} = turma_com_dois(ctx)

      {:ok, cancelado} =
        Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{}, appt.version)

      assert {:error, :block_not_open} =
               Scheduling.transition_participant(
                 ctx.scope,
                 appt.id,
                 ctx.paciente.id,
                 :complete,
                 %{},
                 cancelado.version
               )

      # e o bloco continua cancelado
      recarregado = Scheduling.get_appointment!(appt.id, scope: ctx.scope)
      assert recarregado.status == :cancelado
    end

    test "concluir antes de a sessão começar → :session_not_started" do
      ctx = setup_clinic()
      {appt, _p2} = turma_com_dois(ctx)
      # relógio ANTES do início (07:00 < 08:00)
      antes = escopo_em(ctx, at("07:00"))

      assert {:error, :session_not_started} =
               Scheduling.transition_participant(
                 antes,
                 appt.id,
                 ctx.paciente.id,
                 :complete,
                 %{},
                 appt.version
               )
    end

    test "reabrir NÃO exige que a sessão tenha começado" do
      ctx = setup_clinic()
      {appt, _p2} = turma_com_dois(ctx)

      {:ok, a1} =
        Scheduling.transition_participant(
          ctx.scope,
          appt.id,
          ctx.paciente.id,
          :complete,
          %{},
          appt.version
        )

      antes = escopo_em(ctx, at("07:00"))

      assert {:ok, _} =
               Scheduling.transition_participant(
                 antes,
                 appt.id,
                 ctx.paciente.id,
                 :reopen,
                 %{},
                 a1.version
               )
    end
  end

  describe "débito por participante" do
    test "concluir uma presença de pacote debita SÓ aquele pacote" do
      ctx = setup_clinic()
      turma = turma_tipo(ctx)
      p2 = novo_paciente(ctx)

      # ctx.paciente tem pacote; p2 é avulso na turma.
      {:ok, pkg} =
        Packages.create_package(
          %{
            nome: "Pil",
            total: 5,
            falta_punitiva: true,
            cor: "#0FB5A6",
            data_inicio: @segunda,
            patient_id: ctx.paciente.id,
            appointment_type_id: turma.id,
            grade: %{dows: [1], horarios: %{"1" => "08:00"}, professional_id: ctx.prof.id}
          },
          scope: ctx.scope
        )

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: turma.id,
            patient_ids: [p2.id]
          },
          scope: ctx.scope
        )

      # O vínculo entra pela porta que a produção usa — `add_participant` com `package_id`, que
      # carimba só a presença que entrou. Era aqui que este teste chamava `set_package`, a última
      # referência a uma ação sem chamador de produção desde a etapa 2 da A2 (bate-volta da Onda 3).
      {:ok, appt} =
        Scheduling.add_appointment_participants(
          appt,
          %{patient_ids: [ctx.paciente.id], package_id: pkg.id},
          scope: ctx.scope
        )

      {:ok, _} =
        Scheduling.transition_participant(
          ctx.scope,
          appt.id,
          ctx.paciente.id,
          :complete,
          %{},
          appt.version
        )

      recarregado = Packages.get_package!(pkg.id, scope: ctx.scope, load: [:usadas])
      assert recarregado.usadas == 1
    end
  end
end
