defmodule Api.Packages.PackageTest do
  @moduledoc """
  O recurso `Package` (Fatia 3, doc 25/02 §1.5): identidade do pacote, a grade, e o **contador
  derivado** `usadas` com a regra de consumo/falta punitiva (RN-28…RN-31).

  `usadas` é a peça de risco: nunca coluna denormalizada — conta as `Attendance` que consomem
  sessão, com a punição vindo do próprio pacote (revisão 2026-07-24: sem fallback de clínica).
  Como a RLS não é exercida no sandbox (`postgres`/BYPASSRLS), o isolamento é provado por `psql`.
  """
  use Api.DataCase, async: false

  require Ash.Query

  alias Api.Directory
  alias Api.Packages
  alias Api.Records
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp setup_clinic, do: clinica(tipo: [nome: "Pilates #{unico()}"])

  defp create_package(ctx, attrs \\ %{}) do
    base = %{
      nome: "Pilates 10",
      total: 10,
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
    }

    Packages.create_package(Map.merge(base, attrs), scope: ctx.scope)
  end

  # `usadas` conta ATTENDANCES (revisão 2026-07-24), não appointments — o vínculo é por
  # participante. Cada teste de contagem materializa attendances à mão, com o `package_id`
  # apontando para o pacote, e checa o derivado.
  defp attendance(ctx, appt, patient_id, package_id, status, justificada \\ false) do
    att =
      Ash.Seed.seed!(
        Api.Scheduling.Attendance,
        %{
          appointment_id: appt.id,
          patient_id: patient_id,
          package_id: package_id,
          status: status,
          falta_justificada: justificada,
          # espelho do horário do bloco (doc 43 §4) — `Ash.Seed` não passa pela ação que o preenche
          session_starts_at: appt.starts_at
        },
        tenant: ctx.clinic.id
      )

    att
  end

  defp bare_appointment(ctx) do
    Ash.Seed.seed!(
      Api.Scheduling.Appointment,
      %{
        starts_at: at("08:00"),
        ends_at: at("08:50"),
        professional_id: ctx.prof.id,
        appointment_type_id: ctx.tipo.id,
        status: :agendado,
        encaixe: true,
        version: 1,
        pkg_hold: false
      },
      tenant: ctx.clinic.id
    )
  end

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  defp reload(ctx, pkg, load) do
    Packages.get_package!(pkg.id, scope: ctx.scope, load: load)
  end

  describe "criar — identidade e grade" do
    test "cria o pacote com a grade vinculada" do
      ctx = setup_clinic()
      assert {:ok, pkg} = create_package(ctx)

      assert pkg.status == :ativo
      assert pkg.total == 10
      assert pkg.falta_punitiva == true

      pkg = reload(ctx, pkg, [:schedule])
      assert pkg.schedule.dows == [1, 3]
      assert pkg.schedule.professional_id == ctx.prof.id
    end

    test "falta_punitiva é obrigatória — não há padrão de clínica (revisão 2026-07-24)" do
      ctx = setup_clinic()
      assert {:error, %Ash.Error.Invalid{}} = create_package(ctx, %{falta_punitiva: nil})
    end

    test "total precisa ser positivo" do
      ctx = setup_clinic()
      assert {:error, %Ash.Error.Invalid{}} = create_package(ctx, %{total: 0})
    end

    # O teto não é estético: `total` dimensiona a materialização (N blocos criados pelo job) e a
    # massa por pacote (N escritas numa transação única, segurando conexão do pool e os locks da
    # exclusion constraint). Medido em 16,6 queries/sessão no caminho de turma (doc 43 §7): sem
    # teto, um `500` digitado no lugar de `50` projeta ~8.000 queries e ~15 s de transação.
    test "total tem teto de 120 sessões — o que dimensiona a massa e a materialização" do
      ctx = setup_clinic()

      assert {:ok, %{total: 120}} = create_package(ctx, %{total: 120})
      assert {:error, %Ash.Error.Invalid{} = erro} = create_package(ctx, %{total: 121})
      assert Enum.any?(erro.errors, &(Map.get(&1, :field) == :total))
    end

    # A constraint do atributo recusa na entrada da API; a do BANCO protege o dado de qualquer
    # outro caminho (`Ash.Seed`, script, `psql`) — como o piso faz desde o começo.
    test "o teto vale no banco também, não só na fronteira do Ash" do
      ctx = setup_clinic()

      assert_raise Postgrex.Error, ~r/packages_total_max/, fn ->
        Api.Repo.query!(
          "INSERT INTO packages (id, clinic_id, patient_id, appointment_type_id, nome, total, " <>
            "falta_punitiva, cor, data_inicio, status, inserted_at, updated_at) VALUES " <>
            "($1, $2, $3, $4, 'Furão', 500, true, '#0FB5A6', '2027-03-01', 'ativo', now(), now())",
          [
            Ecto.UUID.dump!(Ash.UUID.generate()),
            Ecto.UUID.dump!(ctx.clinic.id),
            Ecto.UUID.dump!(ctx.paciente.id),
            Ecto.UUID.dump!(ctx.tipo.id)
          ]
        )
      end
    end
  end

  describe "usadas — o contador derivado (RN-28…RN-31)" do
    test "pacote novo tem 0 usadas e restantes = total" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx)

      pkg = reload(ctx, pkg, [:usadas, :restantes])
      assert pkg.usadas == 0
      assert pkg.restantes == 10
    end

    test "concluída SEMPRE debita (RN-29)" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx, %{total: 5})
      appt = bare_appointment(ctx)
      attendance(ctx, appt, ctx.paciente.id, pkg.id, :concluida)

      pkg = reload(ctx, pkg, [:usadas, :restantes])
      assert pkg.usadas == 1
      assert pkg.restantes == 4
    end

    test "falta em pacote punitivo e não justificada debita (RN-30/31)" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx, %{falta_punitiva: true})
      appt = bare_appointment(ctx)
      attendance(ctx, appt, ctx.paciente.id, pkg.id, :faltou, false)

      assert reload(ctx, pkg, [:usadas]).usadas == 1
    end

    test "falta JUSTIFICADA nunca debita, mesmo punitivo (RN-30)" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx, %{falta_punitiva: true})
      appt = bare_appointment(ctx)
      attendance(ctx, appt, ctx.paciente.id, pkg.id, :faltou, true)

      assert reload(ctx, pkg, [:usadas]).usadas == 0
    end

    test "falta em pacote NÃO punitivo não debita (RN-31)" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx, %{falta_punitiva: false})
      appt = bare_appointment(ctx)
      attendance(ctx, appt, ctx.paciente.id, pkg.id, :faltou, false)

      assert reload(ctx, pkg, [:usadas]).usadas == 0
    end

    test "prevista/cancelada não debitam" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx, %{total: 5})
      appt = bare_appointment(ctx)
      attendance(ctx, appt, ctx.paciente.id, pkg.id, :prevista)
      appt2 = bare_appointment(ctx)
      attendance(ctx, appt2, ctx.paciente.id, pkg.id, :cancelada)

      assert reload(ctx, pkg, [:usadas]).usadas == 0
    end

    test "attendance de OUTRO pacote não conta para este" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx, %{total: 5})
      {:ok, outro} = create_package(ctx, %{total: 5})
      appt = bare_appointment(ctx)
      attendance(ctx, appt, ctx.paciente.id, outro.id, :concluida)

      assert reload(ctx, pkg, [:usadas]).usadas == 0
    end
  end

  describe "restantes e acabando (derivados)" do
    test "restantes trava em 0 quando usadas passa do total" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx, %{total: 1})
      a1 = bare_appointment(ctx)
      a2 = bare_appointment(ctx)
      attendance(ctx, a1, ctx.paciente.id, pkg.id, :concluida)
      attendance(ctx, a2, ctx.paciente.id, pkg.id, :concluida)

      pkg = reload(ctx, pkg, [:usadas, :restantes])
      assert pkg.usadas == 2
      assert pkg.restantes == 0
    end

    test "acabando quando restam 1 ou 2 e o pacote está ativo" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx, %{total: 3})
      a1 = bare_appointment(ctx)
      attendance(ctx, a1, ctx.paciente.id, pkg.id, :concluida)

      # restantes = 2 → acabando
      assert reload(ctx, pkg, [:acabando]).acabando == true

      a2 = bare_appointment(ctx)
      a3 = bare_appointment(ctx)
      attendance(ctx, a2, ctx.paciente.id, pkg.id, :concluida)
      attendance(ctx, a3, ctx.paciente.id, pkg.id, :concluida)

      # restantes = 0 → não está mais acabando
      assert reload(ctx, pkg, [:acabando]).acabando == false
    end
  end

  describe "tenant e autorização" do
    test "pacote de outra clínica não é legível" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx)

      # Cross-tenant é NotFound (invisível), não Forbidden — Forbidden vazaria a existência.
      outra = setup_clinic()

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Packages.get_package(pkg.id, scope: outra.scope)
    end
  end

  # Bate-volta da Onda 3: o ciclo de vida do pacote (pausar/cancelar) operava sobre o BLOCO,
  # enquanto a massa (etapa 3) opera sobre a PRESENÇA — duas regras opostas para "as sessões deste
  # pacote", no mesmo domínio. Os três testes abaixo são as três portas que isso abria.
  describe "o ciclo de vida do pacote não atropela quem não é do pacote" do
    # O `@segunda` do arquivo já passou; pausar/cancelar só alcançam sessão futura.
    @futuro ~D[2027-03-01]

    defp at_futuro(hhmm) do
      {:ok, dt} = Scheduling.LocalTime.to_utc(@futuro, hhmm, "America/Sao_Paulo")
      dt
    end

    defp turma_tipo(ctx) do
      Directory.create_appointment_type!(
        %{
          nome: "Turma #{System.unique_integer([:positive])}",
          duracao_minutos: 50,
          cor: "#0FB5A6",
          icon: "Users",
          grupo: true,
          capacidade: 4
        },
        tenant: ctx.clinic.id,
        actor: ctx.owner
      )
    end

    defp sessao_de_turma(ctx, tipo, pacientes, pkg_id) do
      [primeiro | resto] = pacientes

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at_futuro("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: tipo.id,
            patient_ids: [primeiro.id],
            package_id: pkg_id
          },
          scope: ctx.scope
        )

      for p <- resto do
        {:ok, _} =
          Scheduling.schedule_appointment(
            %{
              starts_at: at_futuro("08:00"),
              professional_id: ctx.prof.id,
              appointment_type_id: tipo.id,
              patient_ids: [p.id]
            },
            scope: ctx.scope
          )
      end

      appt
    end

    test "cancelar o pacote de um paciente não cancela a turma dos colegas" do
      ctx = setup_clinic()
      tipo = turma_tipo(ctx)
      colega = Records.create_patient!("Colega", %{}, tenant: ctx.clinic.id, actor: ctx.owner)
      {:ok, pkg} = create_package(ctx, %{appointment_type_id: tipo.id})
      appt = sessao_de_turma(ctx, tipo, [ctx.paciente, colega], pkg.id)

      {:ok, _} = Packages.cancel_package(ctx.scope, pkg.id)

      bloco =
        Api.Tenancy.in_clinic(ctx.scope, fn ->
          Scheduling.get_appointment!(appt.id, scope: ctx.scope, load: [:attendances])
        end)

      vivas = Enum.reject(bloco.attendances, &(&1.status == :cancelada))
      assert bloco.status == :agendado, "o bloco do colega foi cancelado junto"
      assert Enum.map(vivas, & &1.patient_id) == [colega.id]
    end

    test "uma presença já cancelada não arrasta o bloco de ninguém" do
      ctx = setup_clinic()
      tipo = turma_tipo(ctx)
      colega = Records.create_patient!("Colega", %{}, tenant: ctx.clinic.id, actor: ctx.owner)
      {:ok, pkg} = create_package(ctx, %{appointment_type_id: tipo.id})
      appt = sessao_de_turma(ctx, tipo, [ctx.paciente, colega], pkg.id)

      att =
        Scheduling.list_attendances!(scope: ctx.scope, query: [filter: [package_id: pkg.id]])
        |> hd()

      Ash.update!(att, %{status: :cancelada},
        action: :transition,
        tenant: ctx.clinic.id,
        authorize?: false
      )

      {:ok, _} = Packages.cancel_package(ctx.scope, pkg.id)

      bloco =
        Api.Tenancy.in_clinic(ctx.scope, fn ->
          Scheduling.get_appointment!(appt.id, scope: ctx.scope)
        end)

      assert bloco.status == :agendado
    end

    test "retomar um pacote cujas seguradas já foram canceladas não estoura" do
      ctx = setup_clinic()
      {:ok, pkg} = create_package(ctx)

      {:ok, _} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at_futuro("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [ctx.paciente.id],
            package_id: pkg.id
          },
          scope: ctx.scope
        )

      {:ok, _} = Packages.pause_package(ctx.scope, pkg.id)
      {:ok, _} = Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :todas})

      assert {:ok, retomado} = Packages.resume_package(ctx.scope, pkg.id)
      assert retomado.status == :ativo
    end
  end
end
