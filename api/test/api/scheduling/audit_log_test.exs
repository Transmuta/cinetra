defmodule Api.Scheduling.AuditLogTest do
  @moduledoc """
  A leitura da trilha para a tela `/configuracoes/auditoria` (doc 25 §11.4):
  `Api.Scheduling.list_audit_log/2` — feed paginado, filtros, o diff campo-a-campo encadeado
  (consequência do `:changes_only`, A-D13) e o enriquecimento de autor/registro.

  A RLS (ADR-018) **não** é exercida aqui — o sandbox conecta como `postgres` (BYPASSRLS). A
  prova do isolamento das tabelas de versão é por `psql`, no critério de pronto da fatia.
  """
  use Api.DataCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp email, do: "audit-#{System.unique_integer([:positive])}@example.com"

  defp setup_clinic do
    owner = Accounts.register_user!("Dona Ana", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    scope = scope_for(owner, clinic)
    prof = Directory.create_professional!("Dra. Bea", %{}, tenant: clinic.id, actor: owner)

    tipo =
      Directory.create_appointment_type!(
        %{nome: "Sessão #{System.unique_integer([:positive])}", duracao_minutos: 50, cor: "#0FB5A6", icon: "Activity"},
        tenant: clinic.id,
        actor: owner
      )

    paciente = Records.create_patient!("Caio Paciente", %{}, tenant: clinic.id, actor: owner)

    %{owner: owner, clinic: clinic, scope: scope, prof: prof, tipo: tipo, paciente: paciente}
  end

  defp member_with_role(clinic, papel, professional_id \\ nil) do
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

  defp schedule(ctx, attrs \\ %{}) do
    base = %{
      starts_at: at("08:00"),
      professional_id: ctx.prof.id,
      appointment_type_id: ctx.tipo.id,
      patient_ids: [ctx.paciente.id]
    }

    {:ok, appt} = Scheduling.schedule_appointment(Map.merge(base, attrs), scope: ctx.scope)
    appt
  end

  # Um agendamento com uma vida: criado → remarcado (08→09) → cancelado. Três versões de
  # `Appointment`, na ordem, todas do owner.
  defp appt_with_history(ctx) do
    appt = schedule(ctx)

    {:ok, _} =
      Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{starts_at: at("09:00")})

    {:ok, _} =
      Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{cancel_reason: "paciente pediu"})

    appt
  end

  defp actions(entries), do: Enum.map(entries, & &1.action)

  describe "feed cronológico e paginação" do
    test "devolve as entradas do mais recente para o mais antigo, com meta de página" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: entries, page: page} = Scheduling.list_audit_log(ctx.scope)

      # Três versões: cancel, reschedule, schedule — nesta ordem (recência).
      assert actions(entries) == [:cancel, :reschedule, :schedule]
      assert page.total == 3
      assert page.offset == 0
      assert page.limit == 50
      assert page.more == false
    end

    test "pagina: limit/offset recortam e `more?` sinaliza continuação" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: first, page: p1} = Scheduling.list_audit_log(ctx.scope, limit: 2, offset: 0)
      assert actions(first) == [:cancel, :reschedule]
      assert p1.total == 3
      assert p1.more == true

      %{entries: second, page: p2} = Scheduling.list_audit_log(ctx.scope, limit: 2, offset: 2)
      assert actions(second) == [:schedule]
      assert p2.more == false
    end

    test "limit fora do teto cai no default; offset negativo vira 0" do
      ctx = setup_clinic()
      schedule(ctx)

      %{page: page} = Scheduling.list_audit_log(ctx.scope, limit: 9_999, offset: -5)
      assert page.limit == 200
      assert page.offset == 0
    end
  end

  describe "diff campo-a-campo (encadeado, :changes_only)" do
    test "remarcar rende um diff de starts_at com o valor anterior" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: entries} = Scheduling.list_audit_log(ctx.scope)
      reschedule = Enum.find(entries, &(&1.action == :reschedule))

      starts = Enum.find(reschedule.diff, &(&1.field == "starts_at"))
      assert starts
      # 08:00 local (11:00Z) → 09:00 local (12:00Z): from e to presentes e distintos.
      refute is_nil(starts.from)
      refute is_nil(starts.to)
      assert starts.from != starts.to
    end

    test "cancelar rende status agendado → cancelado" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: entries} = Scheduling.list_audit_log(ctx.scope)
      cancel = Enum.find(entries, &(&1.action == :cancel))

      status = Enum.find(cancel.diff, &(&1.field == "status"))
      assert status.from == "agendado"
      assert status.to == "cancelado"
    end

    test "o diff não mostra o contador de locking (`version`) nem `ends_at` derivado" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: entries} = Scheduling.list_audit_log(ctx.scope)
      campos = entries |> Enum.flat_map(& &1.diff) |> Enum.map(& &1.field) |> Enum.uniq()

      refute "version" in campos
      refute "ends_at" in campos
      refute "clinic_id" in campos
    end

    # Bate-volta (segurança, informativo): `created_by_id` é uma FK-por-uuid como as outras que
    # o `@audit_diff_ignore` já esconde — um diff `— → <uuid>` não diz nada (o autor já vem por
    # nome em `actor`). Coerência com a intenção declarada da lista de ignore.
    test "o diff não mostra created_by_id (FK-uuid, como as demais FKs)" do
      ctx = setup_clinic()
      schedule(ctx)

      %{entries: entries} = Scheduling.list_audit_log(ctx.scope)
      campos = entries |> Enum.flat_map(& &1.diff) |> Enum.map(& &1.field) |> Enum.uniq()

      refute "created_by_id" in campos
    end
  end

  describe "enriquecimento" do
    test "traz o autor pelo nome e o profissional do registro" do
      ctx = setup_clinic()
      schedule(ctx)

      %{entries: [entry]} = Scheduling.list_audit_log(ctx.scope)

      assert entry.actor == %{id: ctx.owner.id, nome: "Dona Ana"}
      assert entry.professional == %{id: ctx.prof.id, nome: "Dra. Bea"}
      assert entry.status == :agendado
    end
  end

  describe "filtros (§11.4)" do
    test "por registro (record_id): só o histórico daquele agendamento" do
      ctx = setup_clinic()
      alvo = appt_with_history(ctx)
      _outro = schedule(ctx, %{starts_at: at("14:00")})

      %{entries: entries} = Scheduling.list_audit_log(ctx.scope, record_id: alvo.id)

      assert Enum.all?(entries, &(&1.record_id == alvo.id))
      assert actions(entries) == [:cancel, :reschedule, :schedule]
    end

    test "por ação (action_name)" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      %{entries: entries} = Scheduling.list_audit_log(ctx.scope, action_name: :cancel)
      assert actions(entries) == [:cancel]
    end

    # Bate-volta (verificação): o `count: true` da paginação tem que contar o RECORTE, não a
    # clínica inteira — senão o rótulo "X de Z" da tela mentiria sob filtro.
    test "o total da página respeita o filtro record_id (não é a clínica inteira)" do
      ctx = setup_clinic()
      alvo = appt_with_history(ctx)
      _outro = schedule(ctx, %{starts_at: at("14:00")})

      %{page: sem_filtro} = Scheduling.list_audit_log(ctx.scope)
      assert sem_filtro.total == 4

      %{page: com_filtro} = Scheduling.list_audit_log(ctx.scope, record_id: alvo.id)
      assert com_filtro.total == 3
    end

    test "por autor (user_id): a admin que remarca aparece separada do owner" do
      ctx = setup_clinic()
      appt = schedule(ctx)

      admin = member_with_role(ctx.clinic, :admin)
      admin_scope = scope_for(admin, ctx.clinic)

      {:ok, _} =
        Scheduling.transition_appointment(admin_scope, appt.id, :reschedule, %{starts_at: at("09:00")})

      %{entries: only_admin} = Scheduling.list_audit_log(ctx.scope, user_id: admin.id)
      assert actions(only_admin) == [:reschedule]
      assert Enum.all?(only_admin, &(&1.actor.id == admin.id))
    end

    test "por janela (from/to) sobre version_inserted_at" do
      ctx = setup_clinic()
      schedule(ctx)

      futuro = DateTime.add(DateTime.utc_now(), 3600, :second)
      passado = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert %{entries: [_]} = Scheduling.list_audit_log(ctx.scope, from: passado, to: futuro)
      assert %{entries: []} = Scheduling.list_audit_log(ctx.scope, from: futuro)
    end
  end

  describe "resource: :attendance" do
    test "traz as versões de participante enriquecidas com o paciente" do
      ctx = setup_clinic()
      schedule(ctx)

      %{entries: entries} = Scheduling.list_audit_log(ctx.scope, resource: :attendance)

      assert [entry] = entries
      assert entry.patient == %{id: ctx.paciente.id, nome: "Caio Paciente"}
      refute is_nil(entry.appointment_id)
    end

    # Bate-volta (verificação): o diff de attendance também não pode expor FKs-por-uuid
    # (`patient_id`/`appointment_id`) — a mesma regra do `created_by_id` no appointment.
    test "o diff de participante não expõe FKs-uuid (patient_id/appointment_id)" do
      ctx = setup_clinic()
      schedule(ctx)

      %{entries: entries} = Scheduling.list_audit_log(ctx.scope, resource: :attendance)
      campos = entries |> Enum.flat_map(& &1.diff) |> Enum.map(& &1.field) |> Enum.uniq()

      refute "patient_id" in campos
      refute "appointment_id" in campos
      refute "clinic_id" in campos
    end
  end

  describe "autorização (owner·admin) — a porta dos fundos da A7" do
    test "profissional e recepção recebem página vazia" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      prof_user = member_with_role(ctx.clinic, :profissional, ctx.prof.id)
      recep_user = member_with_role(ctx.clinic, :recepcao)

      assert %{entries: []} = Scheduling.list_audit_log(scope_for(prof_user, ctx.clinic))
      assert %{entries: []} = Scheduling.list_audit_log(scope_for(recep_user, ctx.clinic))
    end

    test "owner e admin leem a trilha" do
      ctx = setup_clinic()
      appt_with_history(ctx)

      admin = member_with_role(ctx.clinic, :admin)

      assert %{entries: [_ | _]} = Scheduling.list_audit_log(ctx.scope)
      assert %{entries: [_ | _]} = Scheduling.list_audit_log(scope_for(admin, ctx.clinic))
    end
  end
end
