defmodule Api.Packages.LifecycleTest do
  @moduledoc """
  O ciclo de vida do pacote (Fatia 3, RN-23/25/28…31): o débito derivado das transições da agenda,
  pausar (segura as sessões futuras) e cancelar (libera as futuras). Retomada (GAP-06) fica no passo
  seguinte.
  """
  use Api.DataCase, async: false
  use Oban.Testing, repo: Api.Repo

  alias Api.Accounts
  alias Api.Packages
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp setup_clinic, do: clinica(tipo: [nome: "Pilates #{unico()}"])

  # `now` fixo bem antes da série (segunda 2026-07-20): todas as sessões são "futuras".
  defp scope_before(ctx) do
    {:ok, now} = Scheduling.LocalTime.to_utc(~D[2026-07-13], "08:00", "America/Sao_Paulo")
    membership = Accounts.get_active_membership!(ctx.owner.id, ctx.clinic.id, authorize?: false)
    Api.Scope.with_membership(ctx.owner, membership, now: now)
  end

  defp scope_at(ctx, %DateTime{} = now) do
    membership = Accounts.get_active_membership!(ctx.owner.id, ctx.clinic.id, authorize?: false)
    Api.Scope.with_membership(ctx.owner, membership, now: now)
  end

  defp params(ctx, attrs \\ %{}) do
    Map.merge(
      %{
        nome: "Pilates 4",
        total: 4,
        falta_punitiva: true,
        cor: "#0FB5A6",
        data_inicio: @segunda,
        patient_id: ctx.paciente.id,
        appointment_type_id: ctx.tipo.id,
        grade: %{
          dows: [1, 3],
          horarios: %{"1" => "08:00", "3" => "09:00"},
          professional_id: ctx.prof.id
        }
      },
      attrs
    )
  end

  defp criar_e_materializar(ctx) do
    {:ok, pkg} = Packages.create_series(scope_before(ctx), params(ctx))
    Oban.drain_queue(queue: :housekeeping)
    pkg
  end

  # As sessões visíveis do pacote (passa pela preparation global). Some `pkg_hold`/excluído.
  defp sessoes(ctx, pkg) do
    Scheduling.list_attendances!(
      scope: ctx.scope,
      query: [filter: [package_id: pkg.id]],
      load: [:appointment]
    )
    |> Enum.map(& &1.appointment)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.starts_at, DateTime)
  end

  # O estado CRU das sessões do pacote, direto no banco — RN-05 esconde `pkg_hold` de toda leitura
  # do Ash, então pausar só é verificável por SQL. Sandbox é `postgres` (BYPASSRLS), sem GUC.
  defp sessoes_cruas(pkg) do
    {:ok, %{rows: rows}} =
      Api.Repo.query(
        "SELECT ap.status, ap.pkg_hold FROM appointments ap " <>
          "JOIN attendances at ON at.appointment_id = ap.id WHERE at.package_id = $1",
        [Ecto.UUID.dump!(pkg.id)]
      )

    Enum.map(rows, fn [status, hold] -> %{status: status, pkg_hold: hold} end)
  end

  describe "débito derivado das transições (RN-28…31)" do
    test "concluir uma sessão debita o pacote automaticamente — sem código de débito" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      primeira = hd(sessoes(ctx, pkg))

      # relógio 1h depois do início da primeira sessão (08:00 seg): passa o gate 'começou'
      {:ok, depois} = Scheduling.LocalTime.to_utc(@segunda, "09:00", "America/Sao_Paulo")

      {:ok, _} =
        Scheduling.transition_participant(
          scope_at(ctx, depois),
          primeira.id,
          ctx.paciente.id,
          :complete
        )

      recarregado = Packages.get_package!(pkg.id, scope: ctx.scope, load: [:usadas, :restantes])
      assert recarregado.usadas == 1
      assert recarregado.restantes == 3
    end
  end

  describe "pausar (RN-23)" do
    test "segura as sessões futuras (pkg_hold) — somem da agenda — e o status vira :pausado" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      assert {:ok, pausado} = Packages.pause_package(scope_before(ctx), pkg.id)
      assert pausado.status == :pausado

      # as 4 sessões ficaram com pkg_hold (estado cru) e somem da leitura da agenda (RN-05)
      cruas = sessoes_cruas(pkg)
      assert length(cruas) == 4
      assert Enum.all?(cruas, & &1.pkg_hold)
      assert [] == sessoes(ctx, pkg)

      {:ok, de} = Scheduling.LocalTime.to_utc(~D[2026-07-01], "00:00", "America/Sao_Paulo")
      {:ok, ate} = Scheduling.LocalTime.to_utc(~D[2026-08-30], "00:00", "America/Sao_Paulo")
      assert [] == Scheduling.list_appointments!(de, ate, scope: ctx.scope)
    end

    test "usadas não muda ao pausar — sessão segurada segue prevista" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      {:ok, _} = Packages.pause_package(scope_before(ctx), pkg.id)

      assert Packages.get_package!(pkg.id, scope: ctx.scope, load: [:usadas]).usadas == 0
    end
  end

  describe "pausar numa TURMA não esconde a sessão do colega (doc 43 §5c)" do
    # O achado: `pkg_hold` era do BLOCO, e pausar o pacote da Maria tirava o Pilates das terças da
    # agenda do João e da Ana junto (`bloco_visivel_depois: 0` com `participantes_do_bloco: 2`).
    test "a presença é segurada, o bloco fica de pé e o colega continua vendo a sessão" do
      ctx = setup_clinic()
      turma = tipo!(ctx, nome: "Turma #{unico()}", icon: "Users", grupo: true, capacidade: 4)
      colega = paciente!(ctx, "Colega #{unico()}")

      {:ok, pkg} =
        Packages.create_package(params(ctx, %{appointment_type_id: turma.id}), scope: ctx.scope)

      {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, "08:00", "America/Sao_Paulo")

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: dt,
            professional_id: ctx.prof.id,
            appointment_type_id: turma.id,
            patient_ids: [ctx.paciente.id],
            package_id: pkg.id
          },
          scope: ctx.scope
        )

      {:ok, appt} =
        Scheduling.add_appointment_participants(appt, %{patient_ids: [colega.id]},
          scope: ctx.scope
        )

      assert length(appt.attendances) == 2

      assert {:ok, pausado} = Packages.pause_package(scope_before(ctx), pkg.id)
      assert pausado.status == :pausado

      # O bloco continua na agenda…
      visivel = Scheduling.get_appointment!(appt.id, scope: ctx.scope, load: [:attendances])
      assert visivel.pkg_hold == false
      # …e com o colega dentro; a presença do pacote sumiu da leitura.
      assert Enum.map(visivel.attendances, & &1.patient_id) == [colega.id]

      # a presença do dono do pacote existe, segurada (estado cru — a leitura do Ash a esconde)
      {:ok, %{rows: [[hold]]}} =
        Api.Repo.query(
          "SELECT pkg_hold FROM attendances WHERE package_id = $1",
          [Ecto.UUID.dump!(pkg.id)]
        )

      assert hold == true
    end

    test "retomar tira a presença segurada da turma sem cancelar a sessão do colega" do
      ctx = setup_clinic()
      turma = tipo!(ctx, nome: "Turma #{unico()}", icon: "Users", grupo: true, capacidade: 4)
      colega = paciente!(ctx, "Colega #{unico()}")

      {:ok, pkg} =
        Packages.create_package(params(ctx, %{appointment_type_id: turma.id}), scope: ctx.scope)

      {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, "08:00", "America/Sao_Paulo")

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: dt,
            professional_id: ctx.prof.id,
            appointment_type_id: turma.id,
            patient_ids: [ctx.paciente.id],
            package_id: pkg.id
          },
          scope: ctx.scope
        )

      {:ok, _} =
        Scheduling.add_appointment_participants(appt, %{patient_ids: [colega.id]},
          scope: ctx.scope
        )

      {:ok, _} = Packages.pause_package(scope_before(ctx), pkg.id)

      {:ok, hoje} = Scheduling.LocalTime.to_utc(~D[2026-08-05], "07:00", "America/Sao_Paulo")
      assert {:ok, ativo} = Packages.resume_package(scope_at(ctx, hoje), pkg.id)
      assert ativo.status == :ativo

      # O bloco do colega segue vivo e agendado — a retomada não cancelou a turma.
      sobrevivente = Scheduling.get_appointment!(appt.id, scope: ctx.scope, load: [:attendances])
      assert sobrevivente.status == :agendado
      assert Enum.map(sobrevivente.attendances, & &1.patient_id) == [colega.id]
    end
  end

  describe "retomar reprojetando (GAP-06)" do
    test "retomar traz N sessões novas a partir de hoje — nunca no passado" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      {:ok, _} = Packages.pause_package(scope_before(ctx), pkg.id)

      {:ok, hoje} = Scheduling.LocalTime.to_utc(~D[2026-08-05], "07:00", "America/Sao_Paulo")
      assert {:ok, ativo} = Packages.resume_package(scope_at(ctx, hoje), pkg.id)
      assert ativo.status == :ativo
      # a re-materialização é assíncrona (job), como na criação
      Oban.drain_queue(queue: :housekeeping)

      # as 4 seguradas viraram canceladas (história); 4 novas nasceram
      cruas = sessoes_cruas(pkg)
      assert Enum.count(cruas, &(&1.status == "cancelado")) == 4
      assert Enum.count(cruas, &(&1.status != "cancelado")) == 4

      # nenhuma das novas cai antes de hoje
      novas_datas =
        sessoes(ctx, pkg)
        |> Enum.map(&Scheduling.LocalTime.to_local_date(&1.starts_at, "America/Sao_Paulo"))

      assert length(novas_datas) == 4
      assert Enum.all?(novas_datas, &(not Date.before?(&1, ~D[2026-08-05])))
    end

    test "usadas sobrevive à retomada — o que foi consumido não volta" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      # conclui a primeira sessão (consome 1)
      primeira = hd(sessoes(ctx, pkg))
      {:ok, depois} = Scheduling.LocalTime.to_utc(@segunda, "09:00", "America/Sao_Paulo")

      {:ok, _} =
        Scheduling.transition_participant(
          scope_at(ctx, depois),
          primeira.id,
          ctx.paciente.id,
          :complete
        )

      {:ok, _} = Packages.pause_package(scope_at(ctx, depois), pkg.id)
      {:ok, hoje} = Scheduling.LocalTime.to_utc(~D[2026-08-05], "07:00", "America/Sao_Paulo")
      {:ok, _} = Packages.resume_package(scope_at(ctx, hoje), pkg.id)
      Oban.drain_queue(queue: :housekeeping)

      # 1 consumida + 3 reprojetadas = ainda 1 usada, 3 restantes
      recarregado = Packages.get_package!(pkg.id, scope: ctx.scope, load: [:usadas, :restantes])
      assert recarregado.usadas == 1
      assert recarregado.restantes == 3
    end
  end

  describe "cancelar (RN-25)" do
    test "cancela as sessões futuras e o pacote" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      assert {:ok, cancelado} = Packages.cancel_package(scope_before(ctx), pkg.id)
      assert cancelado.status == :cancelado

      cruas = sessoes_cruas(pkg)
      assert length(cruas) == 4
      assert Enum.all?(cruas, &(&1.status == "cancelado"))
    end

    test "cancelar um pacote PAUSADO cancela as seguradas (bate-volta: era 500 + órfãs)" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      # pausa primeiro: as 4 futuras ficam seguradas (pkg_hold), invisíveis à leitura normal
      {:ok, _} = Packages.pause_package(scope_before(ctx), pkg.id)

      # cancelar depois de pausar é o fluxo RN-25 ("inclusive as seguradas por uma pausa anterior")
      assert {:ok, cancelado} = Packages.cancel_package(scope_before(ctx), pkg.id)
      assert cancelado.status == :cancelado

      cruas = sessoes_cruas(pkg)
      assert length(cruas) == 4

      assert Enum.all?(cruas, &(&1.status == "cancelado")),
             "sessão segurada ficou órfã: cancelar não alcançou as seguradas por HideHeld"
    end

    test "cancelar ANTES da materialização impede sessões órfãs (bate-volta: job ignorava status)" do
      ctx = setup_clinic()
      # cria a série (enfileira o job; Oban manual não roda ainda)
      {:ok, pkg} = Packages.create_series(scope_before(ctx), params(ctx))
      # cancela ANTES de materializar
      {:ok, cancelado} = Packages.cancel_package(scope_before(ctx), pkg.id)
      assert cancelado.status == :cancelado

      # só AGORA o job roda: deve PULAR (pacote cancelado), não criar sessões para um cancelado
      Oban.drain_queue(queue: :housekeeping)

      assert sessoes_cruas(pkg) == [],
             "materializer criou sessões para um pacote já cancelado (órfãs ocupando a agenda)"
    end

    test "cancelar libera a agenda (as sessões saem)" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      {:ok, _} = Packages.cancel_package(scope_before(ctx), pkg.id)

      {:ok, de} = Scheduling.LocalTime.to_utc(~D[2026-07-01], "00:00", "America/Sao_Paulo")
      {:ok, ate} = Scheduling.LocalTime.to_utc(~D[2026-08-30], "00:00", "America/Sao_Paulo")
      # cancelado não conflita nem aparece como bloco ativo
      ativos =
        Scheduling.list_appointments!(de, ate, scope: ctx.scope)
        |> Enum.reject(&(&1.status == :cancelado))

      assert ativos == []
    end
  end
end
