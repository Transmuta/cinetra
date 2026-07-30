defmodule Api.Packages.BulkTest do
  @moduledoc """
  Massa por pacote (Frente 6/A2 etapa 3, doc 41; contrato [`09 §3.1.1` ponto 3]): `bulk_adjust` e
  `bulk_cancel` resolvem o alvo como o conjunto de **presenças** daquele `package_id` — nunca o
  bloco de grupo inteiro.

  É aqui que a lacuna do protótipo mordia: lá a massa operava sobre o `appointment`, então cancelar
  um pacote de Pilates cancelava a turma **dos outros pacientes** junto. A regra: se a presença é a
  única viva do bloco, o bloco morre/se move com ela; se há outros participantes, mexe-se só na
  presença.
  """
  use Api.DataCase, async: false

  alias Api.Directory
  alias Api.Packages
  alias Api.Scheduling

  # Uma segunda-feira bem no futuro: a massa só alcança sessões de hoje em diante.
  @segunda ~D[2027-03-01]

  # A fábrica é a compartilhada (`Api.Generators`, importada pelo `DataCase`); aqui só o que é
  # deste teste: a turma no lugar do individual e um segundo profissional para a massa mover.
  defp setup_clinic do
    ctx = clinica(tipo: [nome: "Pilates #{unico()}", icon: "Users", grupo: true, capacidade: 4])
    Map.put(ctx, :outra_prof, profissional!(ctx, "Dr. Y"))
  end

  # Um usuário com papel `profissional` vinculado a `professional_id` — o papel menos privilegiado
  # com acesso à agenda, e o que as policies A7/A9 recortam.
  defp scope_profissional(ctx, professional_id),
    do: escopo_de_membro!(ctx, :profissional, professional_id)

  defp novo_paciente(ctx), do: paciente!(ctx, "Paciente #{unico()}")

  defp pacote(ctx, paciente) do
    Packages.create_package!(
      %{
        nome: "Pilates 10",
        total: 10,
        falta_punitiva: true,
        cor: "#0FB5A6",
        data_inicio: @segunda,
        patient_id: paciente.id,
        appointment_type_id: ctx.tipo.id,
        grade: %{dows: [1], horarios: %{"1" => "08:00"}, professional_id: ctx.prof.id}
      },
      scope: ctx.scope
    )
  end

  defp at(data, hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(data, hhmm, "America/Sao_Paulo")
    dt
  end

  # Uma sessão do pacote em `data`/`hhmm`, com os `extras` como colegas de turma.
  defp sessao(ctx, pkg, paciente, data, hhmm, extras \\ []) do
    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: at(data, hhmm),
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [paciente.id],
          package_id: pkg.id
        },
        scope: ctx.scope
      )

    Enum.each(extras, &sessao_avulsa(ctx, &1, data, hhmm))

    appt
  end

  # Sessão sem pacote — colega de turma, ou o bloco que já ocupa o destino.
  defp sessao_avulsa(ctx, paciente, data, hhmm) do
    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: at(data, hhmm),
          professional_id: ctx.prof.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [paciente.id]
        },
        scope: ctx.scope
      )

    appt
  end

  defp recarrega(ctx, appt_id) do
    Api.Tenancy.in_clinic(ctx.scope, fn ->
      Scheduling.get_appointment!(appt_id, scope: ctx.scope, load: [:attendances])
    end)
  end

  defp presencas_vivas(ctx, appt_id),
    do: recarrega(ctx, appt_id).attendances |> Enum.reject(&(&1.status == :cancelada))

  describe "bulk_cancel" do
    test "numa turma com outros participantes, some só a presença do pacote" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      colega = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00", [colega])

      assert {:ok, %{afetadas: 1}} =
               Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :todas})

      vivas = presencas_vivas(ctx, appt.id)
      assert Enum.map(vivas, & &1.patient_id) == [colega.id]
      # o bloco sobrevive para quem ficou
      assert recarrega(ctx, appt.id).status == :agendado
    end

    test "numa sessão individual, o bloco inteiro é cancelado" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00")

      assert {:ok, %{afetadas: 1}} = Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :todas})

      assert recarrega(ctx, appt.id).status == :cancelado
    end

    test "escopo :esta mexe só na sessão de referência" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      a1 = sessao(ctx, pkg, dono, @segunda, "08:00")
      a2 = sessao(ctx, pkg, dono, Date.add(@segunda, 7), "08:00")

      assert {:ok, %{afetadas: 1}} =
               Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :esta, appointment_id: a1.id})

      assert recarrega(ctx, a1.id).status == :cancelado
      assert recarrega(ctx, a2.id).status == :agendado
    end

    test "escopo :proximas pega da referência para a frente" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      a1 = sessao(ctx, pkg, dono, @segunda, "08:00")
      a2 = sessao(ctx, pkg, dono, Date.add(@segunda, 7), "08:00")
      a3 = sessao(ctx, pkg, dono, Date.add(@segunda, 14), "08:00")

      assert {:ok, %{afetadas: 2}} =
               Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :proximas, appointment_id: a2.id})

      assert recarrega(ctx, a1.id).status == :agendado
      assert recarrega(ctx, a2.id).status == :cancelado
      assert recarrega(ctx, a3.id).status == :cancelado
    end

    test "sessão de referência que não é do pacote é 404" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      avulso = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      _ = sessao(ctx, pkg, dono, @segunda, "08:00")
      # bloco de outro paciente, sem vínculo com este pacote
      alheia = sessao_avulsa(ctx, avulso, Date.add(@segunda, 1), "10:00")

      assert {:error, :not_found} =
               Packages.bulk_cancel(ctx.scope, pkg.id, %{
                 escopo: :esta,
                 appointment_id: alheia.id
               })
    end
  end

  describe "profissional inativo (bate-volta do fechamento, 2026-07-26)" do
    # A sonda: `bulk_adjust` com `professional_id` de um profissional **inativo** devolvia
    # `{:ok, %{afetadas: 1}}` e a sessão ia parar na coluna dele. De OUTRA clínica já era 422
    # ("profissional não encontrado nesta clínica"); inativo passava.
    #
    # A causa é anterior à massa e vale para o remarcar do drawer também: `ReferencesActive` só
    # estava em `:schedule`. `:reschedule` **aceita** `professional_id` e não validava — então
    # `:schedule` e `:reschedule` respondiam diferente à mesma pergunta ("posso pôr sessão na
    # coluna deste profissional?"), que é a forma que o `pkgOf` do protótipo tem de voltar.
    test "a massa não move sessão para a coluna de um profissional inativo" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00")

      {:ok, _} = Directory.deactivate_professional(ctx.outra_prof, %{}, scope: ctx.scope)

      assert {:error, %Ash.Error.Invalid{} = erro} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_profissional: true,
                 professional_id: ctx.outra_prof.id
               })

      assert Enum.any?(erro.errors, &(Map.get(&1, :field) == :professional_id))
      # e nada se moveu: a massa é tudo-ou-nada
      assert recarrega(ctx, appt.id).professional_id == ctx.prof.id
    end

    test "o remarcar do drawer também recusa — é a mesma pergunta, uma resposta só" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00")

      {:ok, _} = Directory.deactivate_professional(ctx.outra_prof, %{}, scope: ctx.scope)

      assert {:error, %Ash.Error.Invalid{} = erro} =
               Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{
                 professional_id: ctx.outra_prof.id
               })

      assert Enum.any?(erro.errors, &(Map.get(&1, :field) == :professional_id))
    end

    # A contraprova: TIPO arquivado não pode bloquear a remarcação — doc 25 §7 é literal
    # ("existente continua válido"). Arquivar um tipo tira-o do catálogo dali para a frente; a
    # sessão que já existe continua remarcável.
    test "tipo arquivado NÃO impede remarcar o que já existe" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00")

      {:ok, _} = Directory.archive_appointment_type(ctx.tipo, %{}, scope: ctx.scope)

      assert {:ok, movido} =
               Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{
                 starts_at: at(@segunda, "10:00")
               })

      assert movido.starts_at == at(@segunda, "10:00")
    end
  end

  describe "pacote inexistente" do
    test "é 404, não sucesso silencioso com zero afetadas" do
      ctx = setup_clinic()

      assert {:error, :not_found} =
               Packages.bulk_cancel(ctx.scope, Ash.UUID.generate(), %{escopo: :todas})

      assert {:error, :not_found} =
               Packages.bulk_cancel(ctx.scope, "não-é-uuid", %{escopo: :todas})
    end

    test "pacote de outra clínica não é alcançável" do
      ctx = setup_clinic()
      outra = setup_clinic()
      alheio = pacote(outra, novo_paciente(outra))

      assert {:error, :not_found} = Packages.bulk_cancel(ctx.scope, alheio.id, %{escopo: :todas})
    end
  end

  describe "bulk_adjust" do
    test "sessão individual é remarcada no lugar (mesmo bloco)" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00")

      assert {:ok, %{afetadas: 1}} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_horario: true,
                 hhmm: "09:00"
               })

      movido = recarrega(ctx, appt.id)
      assert movido.starts_at == at(@segunda, "09:00")
      # continua sendo o mesmo bloco, com a mesma presença carimbada
      assert [%{package_id: pkg_id}] = movido.attendances
      assert pkg_id == pkg.id
    end

    test "troca de profissional sem mexer no horário" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00")

      assert {:ok, %{afetadas: 1}} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_profissional: true,
                 professional_id: ctx.outra_prof.id
               })

      movido = recarrega(ctx, appt.id)
      assert movido.professional_id == ctx.outra_prof.id
      assert movido.starts_at == at(@segunda, "08:00")
    end

    test "numa turma, a presença é destacada do bloco antigo e reinserida no novo" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      colega = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00", [colega])

      assert {:ok, %{afetadas: 1}} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_horario: true,
                 hhmm: "09:00"
               })

      # o bloco antigo fica de pé, com o colega, no horário original
      antigo = recarrega(ctx, appt.id)
      assert antigo.starts_at == at(@segunda, "08:00")
      assert Enum.map(antigo.attendances, & &1.patient_id) == [colega.id]

      # e a sessão do pacote virou um bloco novo às 09:00, ainda vinculada ao pacote
      nova = sessao_do_pacote(ctx, pkg.id)
      assert nova.starts_at == at(@segunda, "09:00")
      assert Enum.map(nova.attendances, & &1.patient_id) == [dono.id]
    end

    test "reinserção funde numa turma que já existe no destino" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      colega = novo_paciente(ctx)
      vizinho = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      _appt = sessao(ctx, pkg, dono, @segunda, "08:00", [colega])
      # já existe turma no destino
      destino = sessao_avulsa(ctx, vizinho, @segunda, "09:00")

      assert {:ok, %{afetadas: 1}} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_horario: true,
                 hhmm: "09:00"
               })

      fundido = recarrega(ctx, destino.id)

      assert Enum.sort(Enum.map(fundido.attendances, & &1.patient_id)) ==
               Enum.sort([vizinho.id, dono.id])
    end

    test "a reinserção preserva a duração e o encaixe do bloco de origem" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      colega = novo_paciente(ctx)
      pkg = pacote(ctx, dono)

      # bloco de 80 min marcado como encaixe, compartilhado com um colega
      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at(@segunda, "08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [dono.id],
            package_id: pkg.id,
            duration_minutos: 80,
            encaixe: true
          },
          scope: ctx.scope
        )

      sessao_avulsa(ctx, colega, @segunda, "08:00")

      assert {:ok, %{afetadas: 1}} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_horario: true,
                 hhmm: "10:00"
               })

      nova = sessao_do_pacote(ctx, pkg.id)

      assert DateTime.diff(nova.ends_at, nova.starts_at, :minute) == 80,
             "a sessão encolheu para a duração padrão do tipo"

      assert nova.encaixe == true, "o bloco reinserido perdeu a classificação de encaixe"
      assert nova.id != appt.id
    end

    test "conflito no destino aborta a massa inteira (nada é escrito pela metade)" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      outro = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      a1 = sessao(ctx, pkg, dono, @segunda, "08:00")
      a2 = sessao(ctx, pkg, dono, Date.add(@segunda, 7), "08:00")

      # ocupa o destino da PRIMEIRA com um tipo individual do mesmo profissional
      individual =
        Directory.create_appointment_type!(
          %{
            nome: "Avaliação #{System.unique_integer([:positive])}",
            duracao_minutos: 50,
            cor: "#D55E00",
            icon: "ClipboardList"
          },
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      {:ok, _} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at(@segunda, "09:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: individual.id,
            patient_ids: [outro.id]
          },
          scope: ctx.scope
        )

      # `Ash.Error.Invalid` (e não o changeset cru que o rollback do Ash devolve): é o que a
      # fronteira sabe virar 422 — ver a normalização em `Api.Packages.Bulk.run/3`.
      assert {:error, %Ash.Error.Invalid{}} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_horario: true,
                 hhmm: "09:00"
               })

      # nenhuma das duas se moveu
      assert recarrega(ctx, a1.id).starts_at == at(@segunda, "08:00")
      assert recarrega(ctx, a2.id).starts_at == at(Date.add(@segunda, 7), "08:00")
    end

    test "sem aplicar nada, não há o que fazer" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      _ = sessao(ctx, pkg, dono, @segunda, "08:00")

      assert {:error, :nada_a_aplicar} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{escopo: :todas})
    end
  end

  # D2 (doc 69 §10 / achado §6.2): a massa com escopo `todas` é "mudei o pacote inteiro" — a GRADE
  # tem de acompanhar. Sem isto, a grade guardada continua a antiga, e é ela que o `Materializer`
  # usa para reprojetar na retomada: pausar+retomar depois de uma massa devolvia as sessões no
  # horário velho, com o profissional velho.
  describe "a massa reescreve a grade do pacote (D2)" do
    defp grade_de(ctx, pkg) do
      Packages.get_package!(pkg.id, scope: ctx.scope, load: [:schedule]).schedule
    end

    test "escopo :todas com horário novo grava o horário na grade" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      sessao(ctx, pkg, dono, @segunda, "08:00")

      assert {:ok, _} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_horario: true,
                 hhmm: "09:00"
               })

      assert %{horarios: %{"1" => "09:00"}} = grade_de(ctx, pkg)
    end

    test "escopo :todas com profissional novo grava o profissional na grade" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      sessao(ctx, pkg, dono, @segunda, "08:00")

      assert {:ok, _} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_profissional: true,
                 professional_id: ctx.outra_prof.id
               })

      assert %{professional_id: prof_id} = grade_de(ctx, pkg)
      assert prof_id == ctx.outra_prof.id
    end

    test "escopo :esta NÃO toca a grade — é remarcação de uma sessão, não do pacote" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00")

      assert {:ok, _} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :esta,
                 appointment_id: appt.id,
                 aplicar_horario: true,
                 hhmm: "09:00"
               })

      assert %{horarios: %{"1" => "08:00"}} = grade_de(ctx, pkg)
    end

    test "a retomada depois da massa reprojeta no horário NOVO (o bug que a D2 fecha)" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      sessao(ctx, pkg, dono, @segunda, "08:00")

      {:ok, _} =
        Packages.bulk_adjust(ctx.scope, pkg.id, %{
          escopo: :todas,
          aplicar_horario: true,
          hhmm: "09:00"
        })

      {:ok, _} = Packages.pause_package(ctx.scope, pkg.id)
      {:ok, _} = Packages.resume_package(ctx.scope, pkg.id)
      Oban.drain_queue(queue: :housekeeping)

      reprojetada = sessao_do_pacote(ctx, pkg.id)
      minutos = Scheduling.LocalTime.to_local_minutes(reprojetada.starts_at, "America/Sao_Paulo")

      assert minutos == 9 * 60,
             "a retomada usou a grade velha — a massa não atualizou a grade"
    end
  end

  describe "o passado não se toca" do
    test "sessão de data passada fica de fora, mesmo ainda agendada" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      futura = sessao(ctx, pkg, dono, @segunda, "08:00")

      passada =
        Ash.Seed.seed!(
          Api.Scheduling.Appointment,
          %{
            starts_at: at(~D[2026-01-05], "08:00"),
            ends_at: at(~D[2026-01-05], "08:50"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            status: :agendado,
            clinic_id: ctx.clinic.id
          },
          tenant: ctx.clinic.id
        )

      Ash.Seed.seed!(
        Api.Scheduling.Attendance,
        %{
          appointment_id: passada.id,
          patient_id: dono.id,
          package_id: pkg.id,
          status: :prevista,
          clinic_id: ctx.clinic.id,
          session_starts_at: passada.starts_at
        },
        tenant: ctx.clinic.id
      )

      assert {:ok, %{afetadas: 1}} = Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :todas})

      assert recarrega(ctx, futura.id).status == :cancelado
      assert recarrega(ctx, passada.id).status == :agendado
    end
  end

  # A sessão viva do pacote (a que sobrou depois de uma reinserção).
  defp sessao_do_pacote(ctx, package_id) do
    [att] =
      Scheduling.list_attendances!(
        scope: ctx.scope,
        query: [filter: [package_id: package_id]]
      )
      |> Enum.reject(&(&1.status == :cancelada))

    recarrega(ctx, att.appointment_id)
  end

  # A2 etapa 3 + bate-volta: a massa escreve em nome do usuário, e as policies do `Appointment`
  # (A7 — o profissional só escreve na PRÓPRIA coluna; A9 — encaixe é de recepção para cima)
  # continuam valendo. Sem isto, a massa é uma porta lateral que contorna as duas.
  describe "a massa respeita as policies do agendamento" do
    test "profissional não empurra a própria sessão para a coluna do colega" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00")
      scope = scope_profissional(ctx, ctx.prof.id)

      assert {:error, _} =
               Packages.bulk_adjust(scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_profissional: true,
                 professional_id: ctx.outra_prof.id
               })

      assert recarrega(ctx, appt.id).professional_id == ctx.prof.id
    end

    test "profissional não liga encaixe pela massa (A9)" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00")
      scope = scope_profissional(ctx, ctx.prof.id)

      assert {:error, _} =
               Packages.bulk_adjust(scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_horario: true,
                 hhmm: "09:00",
                 forcar: true
               })

      assert recarrega(ctx, appt.id).encaixe == false
    end

    test "a recepção continua podendo as duas coisas" do
      ctx = setup_clinic()
      dono = novo_paciente(ctx)
      pkg = pacote(ctx, dono)
      appt = sessao(ctx, pkg, dono, @segunda, "08:00")

      assert {:ok, %{afetadas: 1}} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_profissional: true,
                 professional_id: ctx.outra_prof.id,
                 aplicar_horario: true,
                 hhmm: "09:00",
                 forcar: true
               })

      movido = recarrega(ctx, appt.id)
      assert movido.professional_id == ctx.outra_prof.id
      assert movido.encaixe == true
    end
  end
end
