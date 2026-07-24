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

  alias Api.Accounts
  alias Api.Directory
  alias Api.Packages
  alias Api.Records
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp email, do: "pkg-#{System.unique_integer([:positive])}@example.com"

  defp setup_clinic do
    owner = Accounts.register_user!("Dono", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    scope = scope_for(owner, clinic)
    prof = Directory.create_professional!("Dra. X", %{}, tenant: clinic.id, actor: owner)

    tipo =
      Directory.create_appointment_type!(
        %{
          nome: "Pilates #{System.unique_integer([:positive])}",
          duracao_minutos: 50,
          cor: "#0FB5A6",
          icon: "Activity"
        },
        tenant: clinic.id,
        actor: owner
      )

    paciente = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)
    %{owner: owner, clinic: clinic, scope: scope, prof: prof, tipo: tipo, paciente: paciente}
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

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
          falta_justificada: justificada
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
end
