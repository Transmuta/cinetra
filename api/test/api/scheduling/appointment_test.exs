defmodule Api.Scheduling.AppointmentTest do
  @moduledoc """
  As regras da fatia Agenda (doc 25 §7): duração como snapshot, expediente, a exclusion
  constraint `appointments_no_overlap` e o recorte por papel (A7).

  A RLS (ADR-018) **não** é exercida aqui — o sandbox conecta como `postgres` (BYPASSRLS).
  A prova do isolamento é por `psql`, fora da suíte, e está no critério de pronto da fatia.
  """
  use Api.DataCase, async: false

  require Ash.Query

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling

  # 2026-07-20 é uma segunda-feira; o seed do onboard abre seg–sex 08–12 / 13–18.
  # São Paulo é UTC-3, então 08:00 local = 11:00Z.
  @segunda ~D[2026-07-20]

  defp email, do: "agenda-#{System.unique_integer([:positive])}@example.com"

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

    paciente = Records.create_patient!("Paciente", %{}, tenant: clinic.id, actor: owner)

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

  # "HH:MM" local (São Paulo) → DateTime UTC, na segunda de referência.
  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  defp schedule(ctx, attrs) do
    base = %{
      starts_at: at("08:00"),
      professional_id: ctx.prof.id,
      appointment_type_id: ctx.tipo.id,
      patient_ids: [ctx.paciente.id]
    }

    Scheduling.schedule_appointment(Map.merge(base, attrs), scope: ctx.scope)
  end

  describe "criar — duração e participantes" do
    test "cria o agendamento e uma Attendance por paciente" do
      ctx = setup_clinic()
      assert {:ok, appt} = schedule(ctx, %{})

      assert appt.status == :agendado
      assert appt.encaixe == false

      attendances = Scheduling.list_attendances!(scope: ctx.scope)
      assert [%{patient_id: pid, status: :prevista}] = attendances
      assert pid == ctx.paciente.id
    end

    test "ends_at é snapshot da duração do tipo (A3)" do
      ctx = setup_clinic()
      assert {:ok, appt} = schedule(ctx, %{})
      assert DateTime.diff(appt.ends_at, appt.starts_at, :minute) == 50
    end

    test "mudar a duração do tipo NÃO mexe em agendamento já criado (é snapshot)" do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})

      Directory.update_appointment_type!(ctx.tipo, %{duracao_minutos: 90},
        tenant: ctx.clinic.id,
        actor: ctx.owner
      )

      recarregado = Scheduling.get_appointment!(appt.id, scope: ctx.scope)
      assert DateTime.diff(recarregado.ends_at, recarregado.starts_at, :minute) == 50
    end

    test "duration_minutos sobrepõe a duração do tipo (A-D8)" do
      ctx = setup_clinic()
      assert {:ok, appt} = schedule(ctx, %{duration_minutos: 80})
      assert DateTime.diff(appt.ends_at, appt.starts_at, :minute) == 80
    end

    test "o mesmo paciente duas vezes no mesmo agendamento é recusado" do
      ctx = setup_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               schedule(ctx, %{patient_ids: [ctx.paciente.id, ctx.paciente.id]})
    end
  end

  describe "não-sobreposição — a exclusion constraint (A5)" do
    test "sobrepor o mesmo profissional é recusado com 422, NÃO com 500" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      # 08:30 cai dentro de 08:00–08:50.
      assert {:error, %Ash.Error.Invalid{}} = schedule(ctx, %{starts_at: at("08:30")})
    end

    test "encostar fim-com-início NÃO é conflito ('[)')" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})
      assert {:ok, _} = schedule(ctx, %{starts_at: at("08:50")})
    end

    test "encaixe é imune nos DOIS sentidos (RN-12)" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      # Encaixe por cima de bloco existente passa.
      assert {:ok, _} = schedule(ctx, %{starts_at: at("08:30"), encaixe: true})

      # E bloco normal por cima de encaixe também: o encaixe não é conflitado.
      assert {:ok, _} = schedule(ctx, %{starts_at: at("09:00"), encaixe: true})
      assert {:ok, _} = schedule(ctx, %{starts_at: at("09:10")})
    end

    test "outro profissional no mesmo horário não conflita" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      outro =
        Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      assert {:ok, _} = schedule(ctx, %{professional_id: outro.id})
    end
  end

  describe "expediente — validação independente do conflito (A6/RN-14)" do
    test "fora do expediente é recusado" do
      ctx = setup_clinic()
      # 19:00 local: a clínica fecha 18:00.
      assert {:error, %Ash.Error.Invalid{}} = schedule(ctx, %{starts_at: at("19:00")})
    end

    test "atravessar o almoço é recusado — cabe INTEIRO em UM período" do
      ctx = setup_clinic()
      # 11:30 + 50min = 12:20, atravessando o intervalo 12:00–13:00.
      assert {:error, %Ash.Error.Invalid{}} = schedule(ctx, %{starts_at: at("11:30")})
    end

    test "dia em que a clínica não abre é recusado" do
      ctx = setup_clinic()
      # 2026-07-19 é domingo.
      {:ok, domingo} = Scheduling.LocalTime.to_utc(~D[2026-07-19], "10:00", "America/Sao_Paulo")
      assert {:error, %Ash.Error.Invalid{}} = schedule(ctx, %{starts_at: domingo})
    end

    test "ENCAIXE NÃO LIBERA expediente (A-D2/D14): nem admin agenda fora" do
      ctx = setup_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               schedule(ctx, %{starts_at: at("19:00"), encaixe: true})
    end

    test "feriado da clínica fecha o dia, mesmo com horário livre" do
      ctx = setup_clinic()

      {:ok, _} =
        Scheduling.create_clinic_exception(ctx.scope, %{
          data: @segunda,
          tipo: :fechado,
          nome: "Feriado"
        })

      assert {:error, %Ash.Error.Invalid{}} = schedule(ctx, %{})
    end
  end

  describe "A7/D1 — profissional vê só a própria agenda" do
    test "owner vê a agenda inteira" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      assert [_] = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: ctx.scope)
    end

    test "profissional vê a própria e NÃO vê a do colega" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      outro =
        Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      {:ok, _} = schedule(ctx, %{professional_id: outro.id, starts_at: at("10:00")})

      # Membro ligado ao profissional `outro`.
      user = member_with_role(ctx.clinic, :profissional, outro.id)
      scope = scope_for(user, ctx.clinic)

      assert [appt] = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: scope)
      assert appt.professional_id == outro.id
    end

    test "FAIL-CLOSED: profissional SEM professional_id não vê agenda nenhuma" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      # `Membership.professional_id` é allow_nil? true — o "UUID mole". Este membro existe.
      user = member_with_role(ctx.clinic, :profissional, nil)
      scope = scope_for(user, ctx.clinic)
      assert scope.professional_id == nil

      # Não pode degradar para "sem filtro" e mostrar a clínica inteira.
      assert [] == Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: scope)
    end

    test "recepção vê a agenda inteira" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      user = member_with_role(ctx.clinic, :recepcao)
      scope = scope_for(user, ctx.clinic)

      assert [_] = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: scope)
    end
  end

  describe "A8 — quem pode agendar" do
    test "recepção agenda" do
      ctx = setup_clinic()
      user = member_with_role(ctx.clinic, :recepcao)
      scope = scope_for(user, ctx.clinic)

      assert {:ok, _} = schedule(%{ctx | scope: scope}, %{})
    end

    test "profissional agenda na PRÓPRIA coluna" do
      ctx = setup_clinic()
      user = member_with_role(ctx.clinic, :profissional, ctx.prof.id)
      scope = scope_for(user, ctx.clinic)

      assert {:ok, appt} = schedule(%{ctx | scope: scope}, %{})
      assert appt.professional_id == ctx.prof.id
    end

    test "profissional NÃO agenda na coluna de um colega (A7 na escrita)" do
      ctx = setup_clinic()

      colega =
        Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      user = member_with_role(ctx.clinic, :profissional, ctx.prof.id)
      scope = scope_for(user, ctx.clinic)

      assert {:error, %Ash.Error.Forbidden{}} =
               schedule(%{ctx | scope: scope}, %{professional_id: colega.id})
    end

    test "FAIL-CLOSED: profissional SEM professional_id não agenda em coluna nenhuma" do
      ctx = setup_clinic()
      user = member_with_role(ctx.clinic, :profissional, nil)
      scope = scope_for(user, ctx.clinic)

      assert {:error, %Ash.Error.Forbidden{}} = schedule(%{ctx | scope: scope}, %{})
    end
  end

  describe "A9 — só recepção para cima cria encaixe" do
    test "profissional NÃO cria encaixe" do
      ctx = setup_clinic()
      user = member_with_role(ctx.clinic, :profissional, ctx.prof.id)
      scope = scope_for(user, ctx.clinic)

      # `encaixe = true` é o predicado que ISENTA a linha da exclusion constraint. O papel
      # menos privilegiado não desliga a proteção contra dupla-marcação.
      assert {:error, %Ash.Error.Forbidden{}} =
               schedule(%{ctx | scope: scope}, %{encaixe: true})
    end

    test "profissional continua agendando SEM encaixe" do
      ctx = setup_clinic()
      user = member_with_role(ctx.clinic, :profissional, ctx.prof.id)
      scope = scope_for(user, ctx.clinic)

      assert {:ok, %{encaixe: false}} = schedule(%{ctx | scope: scope}, %{encaixe: false})
    end

    test "recepção cria encaixe" do
      ctx = setup_clinic()
      user = member_with_role(ctx.clinic, :recepcao)
      scope = scope_for(user, ctx.clinic)

      assert {:ok, %{encaixe: true}} = schedule(%{ctx | scope: scope}, %{encaixe: true})
    end

    test "owner cria encaixe" do
      ctx = setup_clinic()
      assert {:ok, %{encaixe: true}} = schedule(ctx, %{encaixe: true})
    end
  end

  describe "A7 na Attendance — o irmão do Appointment" do
    test "profissional só enxerga as Attendances da própria agenda" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      colega =
        Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      {:ok, _} = schedule(ctx, %{professional_id: colega.id, starts_at: at("10:00")})

      user = member_with_role(ctx.clinic, :profissional, colega.id)
      scope = scope_for(user, ctx.clinic)

      assert [attendance] = Scheduling.list_attendances!(scope: scope)
      assert [_, _] = Scheduling.list_attendances!(scope: ctx.scope)

      appt = Scheduling.get_appointment!(attendance.appointment_id, scope: scope)
      assert appt.professional_id == colega.id
    end

    test "FAIL-CLOSED: profissional sem professional_id não vê Attendance nenhuma" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      user = member_with_role(ctx.clinic, :profissional, nil)
      scope = scope_for(user, ctx.clinic)

      assert [] == Scheduling.list_attendances!(scope: scope)
    end
  end

  describe "patient_ids é do tenant" do
    test "paciente de OUTRA clínica é recusado" do
      ctx = setup_clinic()
      outra = setup_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               schedule(ctx, %{patient_ids: [outra.paciente.id]})
    end
  end

  describe "RN-13 — cancelado não conflita" do
    test "cancelar libera o slot para um novo agendamento" do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})

      # Enquanto está `:agendado`, o slot está tomado.
      assert {:error, %Ash.Error.Invalid{}} = schedule(ctx, %{})

      # Não há ação de cancelar nesta fatia (é a Entrega 4); a coluna é escrita direto, como
      # no teste de `pkg_hold`. O que se exercita aqui é o predicado da constraint.
      Api.Repo.query!("UPDATE appointments SET status = 'cancelado' WHERE id = $1", [
        Ecto.UUID.dump!(appt.id)
      ])

      assert {:ok, _} = schedule(ctx, %{})
    end
  end

  describe "pkg_hold — RN-05" do
    test "sessão segurada some de toda leitura" do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})

      # Escrita direta: `pkg_hold` é gancho da Fatia 3, sem ação de UI ainda.
      Api.Repo.query!("UPDATE appointments SET pkg_hold = true WHERE id = $1", [
        Ecto.UUID.dump!(appt.id)
      ])

      assert [] == Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: ctx.scope)
    end
  end

  describe "trilha de auditoria (A-D6c)" do
    test "criar um agendamento grava uma versão com a ação e o autor" do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})

      versions =
        Api.Scheduling.Appointment.Version
        |> Ash.Query.filter(version_source_id: appt.id)
        |> Ash.read!(tenant: ctx.clinic.id, authorize?: false)

      assert [version] = versions
      assert version.version_action_name == :schedule
      assert version.user_id == ctx.owner.id
      assert version.clinic_id == ctx.clinic.id
    end

    test "a versão de Attendance também é gravada (A-D14)" do
      ctx = setup_clinic()
      {:ok, _appt} = schedule(ctx, %{})

      versions =
        Api.Scheduling.Attendance.Version
        |> Ash.read!(tenant: ctx.clinic.id, authorize?: false)

      assert [_] = versions
    end

    # O recurso `*.Version` nasce SEM authorizer, o que torna `authorize?: true` um no-op —
    # era a porta dos fundos da A7. Nota sobre a forma do resultado: leitura barrada por
    # policy devolve `{:ok, []}`, não `Forbidden` (o default do Ash é aplicar a policy como
    # filtro, `return_forbidden_error?: false`). O que se afirma aqui é o que importa: nenhuma
    # linha da trilha atravessa.
    test "a trilha é owner·admin: profissional NÃO lê versão (§11.4)" do
      ctx = setup_clinic()
      {:ok, _appt} = schedule(ctx, %{})

      user = member_with_role(ctx.clinic, :profissional, ctx.prof.id)

      for resource <- [Api.Scheduling.Appointment.Version, Api.Scheduling.Attendance.Version] do
        assert {:ok, []} =
                 Ash.read(resource, tenant: ctx.clinic.id, actor: user, authorize?: true)
      end
    end

    test "recepção também NÃO lê a trilha" do
      ctx = setup_clinic()
      {:ok, _appt} = schedule(ctx, %{})

      user = member_with_role(ctx.clinic, :recepcao)

      assert {:ok, []} =
               Ash.read(Api.Scheduling.Appointment.Version,
                 tenant: ctx.clinic.id,
                 actor: user,
                 authorize?: true
               )
    end

    test "owner lê a trilha" do
      ctx = setup_clinic()
      {:ok, _appt} = schedule(ctx, %{})

      assert {:ok, [_]} =
               Ash.read(Api.Scheduling.Appointment.Version,
                 tenant: ctx.clinic.id,
                 actor: ctx.owner,
                 authorize?: true
               )
    end

    test "a trilha é imutável pela aplicação: nem owner escreve nela" do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})

      [version] =
        Api.Scheduling.Appointment.Version
        |> Ash.read!(tenant: ctx.clinic.id, authorize?: false)

      # Input completo de propósito: um changeset inválido pararia nas validações e nunca
      # chegaria à policy — o teste passaria sem provar nada.
      forjado = %{
        version_source_id: appt.id,
        version_action_type: :update,
        version_action_name: :schedule,
        starts_at: appt.starts_at,
        professional_id: appt.professional_id,
        status: :cancelado,
        changes: %{}
      }

      assert {:error, %Ash.Error.Forbidden{}} =
               Api.Scheduling.Appointment.Version
               |> Ash.Changeset.for_create(:create, forjado,
                 tenant: ctx.clinic.id,
                 actor: ctx.owner,
                 authorize?: true
               )
               |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} =
               version
               |> Ash.Changeset.for_update(:update, %{status: :cancelado},
                 tenant: ctx.clinic.id,
                 actor: ctx.owner,
                 authorize?: true
               )
               |> Ash.update()

      # Apagar versão nem ação tem: o AshPaperTrail gera só `read`/`create`/`update` no
      # recurso de versão. Registrado como asserção para que ganhar um `:destroy` no futuro
      # (por default novo do pacote, por exemplo) não passe calado.
      assert Ash.Resource.Info.action(Api.Scheduling.Appointment.Version, :destroy) == nil
    end
  end
end
