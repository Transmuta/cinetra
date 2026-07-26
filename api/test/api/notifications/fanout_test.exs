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

  defp setup_clinic, do: clinica()

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

  # A segunda-feira da semana passada: dia de expediente (o seed abre seg–sex) e **no passado**,
  # que é o que o gate `SessionStarted` das transições de presença exige. Calculada, não fixa: uma
  # data literal envelhece para o futuro conforme a suíte roda.
  defp segunda_passada(hhmm) do
    hoje = Date.utc_today()
    data = Date.add(hoje, -(Date.day_of_week(hoje) - 1) - 7)
    {:ok, dt} = Scheduling.LocalTime.to_utc(data, hhmm, "America/Sao_Paulo")
    dt
  end

  # Um item de fila que encaixa em qualquer horário (janela `:qualquer`, sem regras).
  defp fila(ctx, scope) do
    {:ok, entry} =
      Waitlist.enqueue_entry(scope, %{
        patient_id:
          Records.create_patient!("Fila #{System.unique_integer([:positive])}", %{},
            tenant: ctx.clinic.id,
            actor: ctx.owner
          ).id,
        prio: :urgente,
        janela: :qualquer,
        professional_ids: [],
        rules: []
      })

    entry
  end

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

      {:ok, _} =
        Scheduling.transition_appointment(owner_scope, appt.id, :reschedule, %{
          starts_at: at("09:00")
        })

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

  # A2 (doc 41 etapa 5): as duas famílias que o doc 31 §3a deixou como "🟡 depois" porque
  # esperavam a fatia de turma/pacote.
  describe "falta e entrada em turma → profissional dono da coluna" do
    test "#46 — falta POR PARTICIPANTE avisa o profissional, com o nome do paciente" do
      ctx = setup_clinic()
      prof_user = member(ctx.clinic, :profissional, ctx.prof.id)
      owner_scope = scope_for(ctx.owner, ctx.clinic)

      {:ok, appt} = schedule(ctx, owner_scope, %{starts_at: segunda_passada("08:00")})

      {:ok, _} =
        Scheduling.transition_participant(owner_scope, appt.id, ctx.paciente.id, :no_show)

      falta = Enum.find(inbox(prof_user, ctx.clinic), &(&1.kind == :appointment_missed))
      assert falta
      assert falta.body =~ "Paciente"
      assert falta.data["patient_id"] == ctx.paciente.id
    end

    test "#46 — o próprio profissional marcando não se notifica" do
      ctx = setup_clinic()
      prof_user = member(ctx.clinic, :profissional, ctx.prof.id)
      prof_scope = scope_for(prof_user, ctx.clinic)

      {:ok, appt} = schedule(ctx, prof_scope, %{starts_at: segunda_passada("08:00")})
      {:ok, _} = Scheduling.transition_participant(prof_scope, appt.id, ctx.paciente.id, :no_show)

      refute :appointment_missed in kinds(prof_user, ctx.clinic)
    end

    test "#46 — concluir NÃO gera notificação (é ruído: doc 31 §3a)" do
      ctx = setup_clinic()
      prof_user = member(ctx.clinic, :profissional, ctx.prof.id)
      owner_scope = scope_for(ctx.owner, ctx.clinic)

      {:ok, appt} = schedule(ctx, owner_scope, %{starts_at: segunda_passada("08:00")})

      {:ok, _} =
        Scheduling.transition_participant(owner_scope, appt.id, ctx.paciente.id, :complete)

      refute :appointment_missed in kinds(prof_user, ctx.clinic)
    end

    # Bate-volta da Onda 3: o `with` começava lendo o BLOCO (uma transação inteira) e só depois
    # perguntava se havia destinatário. Numa clínica sem usuário vinculado ao profissional — o caso
    # comum — eram 4 queries jogadas fora por clique, no caminho mais clicado da agenda.
    test "#46 — sem destinatário, não paga a leitura do bloco" do
      ctx = setup_clinic()
      owner_scope = scope_for(ctx.owner, ctx.clinic)
      {:ok, appt} = schedule(ctx, owner_scope, %{starts_at: segunda_passada("08:00")})

      att =
        Scheduling.list_attendances!(
          tenant: ctx.clinic.id,
          authorize?: false,
          query: [filter: [appointment_id: appt.id]]
        )
        |> hd()

      # ninguém vinculado ao `ctx.prof` → não há quem notificar
      {_, queries} =
        Api.QueryCounter.count(fn ->
          Api.Notifications.Fanout.participant_missed(att, ctx.owner)
        end)

      assert queries <= 2, "leu #{queries} queries para descobrir que não há destinatário"
    end

    test "#47 — entrar numa turma avisa o profissional" do
      ctx = setup_clinic()
      prof_user = member(ctx.clinic, :profissional, ctx.prof.id)
      owner_scope = scope_for(ctx.owner, ctx.clinic)

      turma =
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

      {:ok, _} =
        schedule(ctx, owner_scope, %{appointment_type_id: turma.id})

      colega =
        Records.create_patient!("Colega", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      # mesmo profissional/tipo/horário → funde na turma (o caminho do `:add_participant`)
      {:ok, _} =
        schedule(ctx, owner_scope, %{
          appointment_type_id: turma.id,
          patient_ids: [colega.id]
        })

      assert :participant_added in kinds(prof_user, ctx.clinic)
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
          patient_id:
            Records.create_patient!("Fila", %{}, tenant: ctx.clinic.id, actor: ctx.owner).id,
          prio: :urgente,
          janela: :qualquer,
          professional_ids: [],
          rules: []
        })

      {:ok, appt} = schedule(ctx, owner_scope)
      {:ok, _} = Scheduling.transition_appointment(owner_scope, appt.id, :cancel)

      assert :slot_opened in kinds(recep, ctx.clinic)
    end

    # A2 (doc 41), achado A-5: com o desfecho virando rollup das presenças, a falta deixou de
    # chegar como `:mark_missed` — e o aviso para a fila sumiria assim que a UI migrasse.
    test "falta marcada POR PARTICIPANTE também avisa a recepção" do
      ctx = setup_clinic()
      recep = member(ctx.clinic, :recepcao)
      owner_scope = scope_for(ctx.owner, ctx.clinic)
      fila(ctx, owner_scope)

      {:ok, appt} = schedule(ctx, owner_scope, %{starts_at: segunda_passada("08:00")})

      {:ok, _} =
        Scheduling.transition_participant(owner_scope, appt.id, ctx.paciente.id, :no_show)

      assert :slot_opened in kinds(recep, ctx.clinic)
    end

    test "justificar depois NÃO reavisa a mesma vaga" do
      ctx = setup_clinic()
      recep = member(ctx.clinic, :recepcao)
      owner_scope = scope_for(ctx.owner, ctx.clinic)
      fila(ctx, owner_scope)

      {:ok, appt} = schedule(ctx, owner_scope, %{starts_at: segunda_passada("08:00")})

      {:ok, _} =
        Scheduling.transition_participant(owner_scope, appt.id, ctx.paciente.id, :no_show)

      {:ok, _} =
        Scheduling.transition_participant(owner_scope, appt.id, ctx.paciente.id, :justify, %{
          justificada: true
        })

      # o rollup roda de novo (bloco já em `:faltou`), e o aviso não pode duplicar
      assert Enum.count(kinds(recep, ctx.clinic), &(&1 == :slot_opened)) == 1
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

  describe "massa por pacote → UMA notificação, não N (doc 43 §5b)" do
    test "remarcar 3 sessões manda uma linha com o número, não três \"novo agendamento\"" do
      ctx = setup_clinic()
      # O dono da coluna é quem recebe; quem opera é a recepção (senão o autor se suprime).
      prof_user = member(ctx.clinic, :profissional, ctx.prof.id)
      recep = member(ctx.clinic, :recepcao)
      recep_scope = scope_for(recep, ctx.clinic)

      paciente =
        Records.create_patient!("Massa #{System.unique_integer([:positive])}", %{},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      {:ok, pkg} =
        Api.Packages.create_package(
          %{
            nome: "Pilates 3",
            total: 3,
            falta_punitiva: true,
            cor: "#0FB5A6",
            data_inicio: Date.add(@segunda, 364),
            patient_id: paciente.id,
            appointment_type_id: ctx.tipo.id,
            grade: %{dows: [1], horarios: %{"1" => "08:00"}, professional_id: ctx.prof.id}
          },
          scope: recep_scope
        )

      for i <- 0..2 do
        data = Date.add(@segunda, 364 + 7 * i)
        {:ok, dt} = Scheduling.LocalTime.to_utc(data, "08:00", "America/Sao_Paulo")

        {:ok, _} =
          Scheduling.schedule_appointment(
            %{
              starts_at: dt,
              professional_id: ctx.prof.id,
              appointment_type_id: ctx.tipo.id,
              patient_ids: [paciente.id],
              package_id: pkg.id
            },
            scope: recep_scope
          )
      end

      antes = Enum.frequencies(kinds(prof_user, ctx.clinic))

      assert {:ok, %{afetadas: 3}} =
               Api.Packages.bulk_adjust(recep_scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_horario: true,
                 hhmm: "09:00"
               })

      depois = Enum.frequencies(kinds(prof_user, ctx.clinic))

      # Uma linha agregada…
      assert Map.get(depois, :package_bulk_adjusted, 0) == 1
      # …e NENHUMA por sessão (era 3× "Novo agendamento na sua agenda").
      for kind <- [:appointment_scheduled, :appointment_rescheduled] do
        assert Map.get(depois, kind, 0) == Map.get(antes, kind, 0)
      end

      texto = inbox(prof_user, ctx.clinic) |> Enum.find(&(&1.kind == :package_bulk_adjusted))
      assert texto.body =~ "3 sessões"
      assert texto.body =~ "Pilates 3"
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
