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

  defp setup_clinic, do: clinica()

  # "HH:MM" local (São Paulo) → DateTime UTC, na segunda de referência.
  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  defp grupo_tipo(ctx, capacidade),
    do: tipo!(ctx, nome: "Turma #{unico()}", icon: "Users", grupo: true, capacidade: capacidade)

  defp novo_paciente(ctx), do: paciente!(ctx, "Paciente #{unico()}")

  # Os `code`s estáveis do contrato (doc 25 §5) viajam em `vars[:code]` — é assim que a
  # fronteira HTTP os promove ao topo do 422. Afirmar o código, e não a mensagem, é o que
  # torna o teste um teste de contrato.
  defp codes(%Ash.Error.Invalid{errors: errors}) do
    Enum.flat_map(errors, fn error ->
      case Map.get(error, :vars) do
        vars when is_list(vars) -> List.wrap(Keyword.get(vars, :code))
        _ -> []
      end
    end)
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
        Directory.create_professional!("Dr. Y", %{tel: Api.Generators.telefone_unico()},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

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
        Directory.create_professional!("Dr. Y", %{tel: Api.Generators.telefone_unico()},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      {:ok, _} = schedule(ctx, %{professional_id: outro.id, starts_at: at("10:00")})

      # Membro ligado ao profissional `outro`.
      scope = escopo_de_membro!(ctx, :profissional, outro.id)

      assert [appt] = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: scope)
      assert appt.professional_id == outro.id
    end

    test "FAIL-CLOSED: profissional SEM professional_id não vê agenda nenhuma" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      # `Membership.professional_id` é allow_nil? true — o "UUID mole". Este membro existe.
      scope = escopo_de_membro!(ctx, :profissional, nil)
      assert scope.professional_id == nil

      # Não pode degradar para "sem filtro" e mostrar a clínica inteira.
      assert [] == Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: scope)
    end

    test "recepção vê a agenda inteira" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      scope = escopo_de_membro!(ctx, :recepcao)

      assert [_] = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: scope)
    end
  end

  # A8 mudou em 2026-08-04 (doc 103): o papel `profissional` deixou de agendar. Antes ele
  # agendava na PRÓPRIA coluna, e o A7-na-escrita (`OwnProfessionalColumn`) era o que o mantinha
  # fora da coluna do colega; agora ele não escreve em coluna nenhuma, e o recorte que sobra é
  # só de LEITURA. Os testes desta describe são o gate dessa decisão — se um deles voltar a
  # ficar verde com `{:ok, _}`, a permissão voltou sem que ninguém decidisse.
  describe "A8 — quem pode agendar (o profissional não)" do
    test "recepção agenda" do
      ctx = setup_clinic()
      scope = escopo_de_membro!(ctx, :recepcao)

      assert {:ok, _} = schedule(%{ctx | scope: scope}, %{})
    end

    test "profissional NÃO agenda — nem na PRÓPRIA coluna" do
      ctx = setup_clinic()
      scope = escopo_de_membro!(ctx, :profissional, ctx.prof.id)

      assert {:error, %Ash.Error.Forbidden{}} = schedule(%{ctx | scope: scope}, %{})
    end

    test "profissional NÃO agenda na coluna de um colega" do
      ctx = setup_clinic()
      colega = profissional!(ctx, "Dr. Y")
      scope = escopo_de_membro!(ctx, :profissional, ctx.prof.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               schedule(%{ctx | scope: scope}, %{professional_id: colega.id})
    end

    test "FAIL-CLOSED: profissional SEM professional_id não agenda em coluna nenhuma" do
      ctx = setup_clinic()
      scope = escopo_de_membro!(ctx, :profissional, nil)

      assert {:error, %Ash.Error.Forbidden{}} = schedule(%{ctx | scope: scope}, %{})
    end

    # O CONTROLE POSITIVO da decisão. Sem ele, os quatro asserts acima passariam também se a
    # agenda tivesse sumido para o papel — e "não vê nada" não é o que foi pedido.
    test "e continua LENDO a própria agenda" do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})
      scope = escopo_de_membro!(ctx, :profissional, ctx.prof.id)

      assert [lido] = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: scope)
      assert lido.id == appt.id
    end
  end

  # O resto do ciclo de vida (Entrega 4). "Não pode agendar" não seria nada se ele pudesse
  # remarcar, cancelar, excluir ou fechar o desfecho do bloco que já está lá.
  describe "ciclo de vida — o profissional também não altera o que já existe" do
    setup do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})

      %{
        ctx: ctx,
        appt: appt,
        prof: escopo_de_membro!(ctx, :profissional, ctx.prof.id)
      }
    end

    test "não remarca", %{appt: appt, prof: scope} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Scheduling.reschedule_appointment_slot(appt, %{starts_at: at("09:00")},
                 scope: scope
               )
    end

    test "não cancela", %{appt: appt, prof: scope} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Scheduling.cancel_appointment_slot(appt, %{}, scope: scope)
    end

    test "não exclui", %{appt: appt, prof: scope} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Scheduling.exclude_appointment_slot(appt, %{}, scope: scope)
    end

    test "não tira participante", %{appt: appt, ctx: ctx, prof: scope} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Scheduling.remove_appointment_participants(
                 appt,
                 %{patient_ids: [ctx.paciente.id]},
                 scope: scope
               )
    end

    test "não marca presença", %{ctx: ctx, prof: scope} do
      [presenca] = Scheduling.list_attendances!(scope: ctx.scope)

      assert {:error, %Ash.Error.Forbidden{}} =
               Scheduling.mark_attendance_present(presenca, %{}, scope: scope)
    end

    test "não marca falta", %{ctx: ctx, prof: scope} do
      [presenca] = Scheduling.list_attendances!(scope: ctx.scope)

      assert {:error, %Ash.Error.Forbidden{}} =
               Scheduling.mark_attendance_absent(presenca, %{}, scope: scope)
    end

    # Controle positivo do bloco acima: a presença que ele não altera, ele enxerga.
    test "mas lê as presenças da própria agenda", %{ctx: ctx, prof: scope} do
      assert [_] = Scheduling.list_attendances!(scope: scope)
      assert [_] = Scheduling.list_attendances!(scope: ctx.scope)
    end
  end

  describe "A9 — só recepção para cima cria encaixe" do
    test "profissional NÃO cria encaixe" do
      ctx = setup_clinic()
      scope = escopo_de_membro!(ctx, :profissional, ctx.prof.id)

      # `encaixe = true` é o predicado que ISENTA a linha da exclusion constraint. O papel
      # menos privilegiado não desliga a proteção contra dupla-marcação. Desde a A8 de
      # 2026-08-04 ele já não agenda nem sem encaixe — este teste continua porque a A9 é uma
      # regra PRÓPRIA: se um dia o papel voltar a agendar, ela é o que segue barrando o encaixe.
      assert {:error, %Ash.Error.Forbidden{}} =
               schedule(%{ctx | scope: scope}, %{encaixe: true})
    end

    test "recepção cria encaixe" do
      ctx = setup_clinic()
      scope = escopo_de_membro!(ctx, :recepcao)

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
        Directory.create_professional!("Dr. Y", %{tel: Api.Generators.telefone_unico()},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      {:ok, _} = schedule(ctx, %{professional_id: colega.id, starts_at: at("10:00")})

      scope = escopo_de_membro!(ctx, :profissional, colega.id)

      assert [attendance] = Scheduling.list_attendances!(scope: scope)
      assert [_, _] = Scheduling.list_attendances!(scope: ctx.scope)

      appt = Scheduling.get_appointment!(attendance.appointment_id, scope: scope)
      assert appt.professional_id == colega.id
    end

    test "FAIL-CLOSED: profissional sem professional_id não vê Attendance nenhuma" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      scope = escopo_de_membro!(ctx, :profissional, nil)

      assert [] == Scheduling.list_attendances!(scope: scope)
    end

    # O recorte DENTRO do `load:` de relacionamento — o caminho que o bate-volta pegou
    # falhando aberto.
    #
    # Os dois testes acima leem `Attendance` **de topo**, e essa query recebe o `:scope` direto.
    # A query que o Ash monta para `load: [:attendances]` é outra: ela não herda o contexto da
    # query de cima, só a chave `:shared`. Enquanto o `OwnAgendaOnly` lia o escopo direto do
    # contexto, ele recebia `nil` ali, devolvia "sem papel" e **não filtrava** — dentro do
    # módulo cujo moduledoc existe para evitar fail-open.
    #
    # Não chegou a vazar, porque as `attendances` vinham penduradas em `Appointment`s que o
    # filtro do pai já recortara. Mas a garantia era acidental, e este teste é o que a torna
    # deliberada: se a propagação por `:shared` sumir de `Api.Scope.get_context/1`, ele cai.
    test "o recorte A7 vale também dentro do `load: [:attendances]`" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      colega =
        Directory.create_professional!("Dr. Y", %{tel: Api.Generators.telefone_unico()},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      {:ok, _} = schedule(ctx, %{professional_id: colega.id, starts_at: at("10:00")})

      scope = escopo_de_membro!(ctx, :profissional, colega.id)

      appointments =
        Scheduling.list_appointments!(at("00:00"), at("23:00"),
          scope: scope,
          load: [:attendances]
        )

      # O owner enxerga os dois blocos e as duas presenças; o profissional, só os seus.
      assert [_, _] =
               Scheduling.list_appointments!(at("00:00"), at("23:00"),
                 scope: ctx.scope,
                 load: [:attendances]
               )

      assert [appt] = appointments
      assert appt.professional_id == colega.id
      assert [attendance] = appt.attendances
      assert attendance.appointment_id == appt.id
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

  # Irmão de RN-13: um bloco EXCLUÍDO (soft-delete, doc 40) também tem de liberar o horário —
  # senão um lançamento feito por engano seguiria bloqueando o slot para sempre. Só o banco
  # prova (o predicado parcial da `appointments_no_overlap` precisa de `AND excluded_at IS NULL`);
  # a leitura filtrar não basta, a constraint é DB-level.
  describe "excluído não conflita (predicado da constraint)" do
    test "excluir libera o slot para um novo agendamento" do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})

      # `:agendado` toma o slot.
      assert {:error, %Ash.Error.Invalid{}} = schedule(ctx, %{})

      assert {:ok, _} = Scheduling.transition_appointment(ctx.scope, appt.id, :exclude)

      # Excluído, o mesmo horário volta a ser agendável.
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

  describe "A-D4 — merge idempotente de turma" do
    test "segundo participante no mesmo slot FUNDE no agendamento existente" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 4)
      outro = novo_paciente(ctx)

      assert {:ok, primeiro} = schedule(ctx, %{appointment_type_id: turma.id})

      assert {:ok, segundo} =
               schedule(ctx, %{appointment_type_id: turma.id, patient_ids: [outro.id]})

      # Mesmo bloco, não um segundo: com a exclusion constraint, criar outro Appointment no
      # mesmo profissional/horário seria rejeitado pelo banco (A-D4).
      assert segundo.id == primeiro.id

      assert [_, _] = Scheduling.list_attendances!(scope: ctx.scope)
      assert [_] = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: ctx.scope)
    end

    test "o merge é por profissional/data/hora/TIPO — outro tipo de turma não funde" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 4)
      outra_turma = grupo_tipo(ctx, 4)

      assert {:ok, _} = schedule(ctx, %{appointment_type_id: turma.id})

      # Mesmo profissional e horário, tipo diferente: não é a mesma turma, então vale a
      # não-sobreposição normal.
      assert {:error, %Ash.Error.Invalid{}} =
               schedule(ctx, %{
                 appointment_type_id: outra_turma.id,
                 patient_ids: [novo_paciente(ctx).id]
               })
    end

    test "tipo individual NÃO funde: continua sendo conflito" do
      ctx = setup_clinic()
      assert {:ok, _} = schedule(ctx, %{})

      assert {:error, %Ash.Error.Invalid{}} =
               schedule(ctx, %{patient_ids: [novo_paciente(ctx).id]})
    end

    test "o mesmo paciente duas vezes na turma é recusado também pelo merge" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 4)

      assert {:ok, _} = schedule(ctx, %{appointment_type_id: turma.id})
      assert {:error, %Ash.Error.Invalid{}} = schedule(ctx, %{appointment_type_id: turma.id})
    end

    test "funde também com o corpo COMO CHEGA DO HTTP: chaves string e `starts_at` ISO" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 4)

      {:ok, primeiro} = schedule(ctx, %{appointment_type_id: turma.id})

      # É o formato exato que o controller monta (`whitelist/2` devolve chave atom com valor
      # cru do JSON). Se o lookup só entendesse `%DateTime{}`, o merge não aconteceria **em
      # produção** e a suíte continuaria verde — a mesma classe de bug que já mordeu esta
      # fatia duas vezes.
      attrs = %{
        "starts_at" => DateTime.to_iso8601(at("08:00")),
        "professional_id" => ctx.prof.id,
        "appointment_type_id" => turma.id,
        "patient_ids" => [novo_paciente(ctx).id]
      }

      assert {:ok, segundo} = Scheduling.schedule_appointment(attrs, scope: ctx.scope)
      assert segundo.id == primeiro.id
    end

    test "funde também quando o chamador passa `tenant:` cru, sem escopo" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 4)

      {:ok, primeiro} = schedule(ctx, %{appointment_type_id: turma.id})

      attrs = %{
        starts_at: at("08:00"),
        professional_id: ctx.prof.id,
        appointment_type_id: turma.id,
        patient_ids: [novo_paciente(ctx).id]
      }

      assert {:ok, segundo} =
               Scheduling.schedule_appointment(attrs,
                 tenant: ctx.clinic.id,
                 actor: ctx.owner
               )

      assert segundo.id == primeiro.id
    end

    test "tipo de OUTRA clínica não funde nem agenda" do
      ctx = setup_clinic()
      outra = setup_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               schedule(ctx, %{appointment_type_id: outra.tipo.id})
    end

    test "`starts_at` malformado não funde: quem recusa é a ação, não o lookup" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 4)

      attrs = %{
        starts_at: "isto-não-é-uma-data",
        professional_id: ctx.prof.id,
        appointment_type_id: turma.id,
        patient_ids: [ctx.paciente.id]
      }

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.schedule_appointment(attrs, scope: ctx.scope)
    end

    test "o merge grava versão de trilha do participante que entrou (A-D14)" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 4)

      {:ok, _} = schedule(ctx, %{appointment_type_id: turma.id})

      entrou = novo_paciente(ctx)

      {:ok, _} = schedule(ctx, %{appointment_type_id: turma.id, patient_ids: [entrou.id]})

      # UMA linha, a de quem entrou: a presença que nasceu junto com a turma não é evento próprio
      # (quem conta esse fato é "Criou o agendamento", que já nomeia quem está nele).
      %{entries: entries} = Api.Audit.list_events(ctx.scope, resource: :attendance)
      assert [evento] = entries
      assert evento.patient.id == entrou.id
    end
  end

  describe "A-D3 — capacidade de turma (teto soft, `group_full`)" do
    test "turma no limite passa" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 2)

      assert {:ok, _} =
               schedule(ctx, %{
                 appointment_type_id: turma.id,
                 patient_ids: [ctx.paciente.id, novo_paciente(ctx).id]
               })
    end

    test "limite + 1 é recusado com `group_full`, sem campo" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 2)

      assert {:error, %Ash.Error.Invalid{} = erro} =
               schedule(ctx, %{
                 appointment_type_id: turma.id,
                 patient_ids: [ctx.paciente.id, novo_paciente(ctx).id, novo_paciente(ctx).id]
               })

      assert "group_full" in codes(erro)
    end

    test "o MERGE também respeita o teto — é o furo do protótipo" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 2)

      {:ok, _} =
        schedule(ctx, %{
          appointment_type_id: turma.id,
          patient_ids: [ctx.paciente.id, novo_paciente(ctx).id]
        })

      assert {:error, %Ash.Error.Invalid{} = erro} =
               schedule(ctx, %{
                 appointment_type_id: turma.id,
                 patient_ids: [novo_paciente(ctx).id]
               })

      assert "group_full" in codes(erro)
    end

    test "encaixe FURA o teto (soft): criar" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 2)

      assert {:ok, _} =
               schedule(ctx, %{
                 appointment_type_id: turma.id,
                 encaixe: true,
                 patient_ids: [ctx.paciente.id, novo_paciente(ctx).id, novo_paciente(ctx).id]
               })
    end

    test "encaixe FURA o teto (soft): merge" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 2)

      {:ok, _} =
        schedule(ctx, %{
          appointment_type_id: turma.id,
          patient_ids: [ctx.paciente.id, novo_paciente(ctx).id]
        })

      assert {:ok, _} =
               schedule(ctx, %{
                 appointment_type_id: turma.id,
                 encaixe: true,
                 patient_ids: [novo_paciente(ctx).id]
               })
    end

    test "tipo individual não tem teto de turma" do
      ctx = setup_clinic()

      assert {:ok, _} =
               schedule(ctx, %{patient_ids: [ctx.paciente.id, novo_paciente(ctx).id]})
    end

    test "sem `capacidade` no tipo, o teto é o `cap_turma_padrao` da clínica" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 10)

      # A coluna é nullable e a exigência "capacidade sse grupo" vive nas ações do tipo —
      # linha antiga (ou escrita fora delas) pode ter grupo sem teto. O fallback existe para
      # esse caso; escrita direta é como os testes de `pkg_hold` e de cancelamento exercitam
      # estado que ainda não tem ação.
      Api.Repo.query!("UPDATE appointment_types SET capacidade = NULL WHERE id = $1", [
        Ecto.UUID.dump!(turma.id)
      ])

      Accounts.update_clinic_settings!(ctx.clinic, %{cap_turma_padrao: 2},
        actor: ctx.owner,
        tenant: ctx.clinic.id
      )

      assert {:error, %Ash.Error.Invalid{} = erro} =
               schedule(ctx, %{
                 appointment_type_id: turma.id,
                 patient_ids: [ctx.paciente.id, novo_paciente(ctx).id, novo_paciente(ctx).id]
               })

      assert "group_full" in codes(erro)
    end
  end

  describe "§7 — tipo arquivado / profissional ou paciente inativo" do
    test "tipo arquivado é recusado" do
      ctx = setup_clinic()
      Directory.archive_appointment_type!(ctx.tipo, tenant: ctx.clinic.id, actor: ctx.owner)

      assert {:error, %Ash.Error.Invalid{}} = schedule(ctx, %{})
    end

    test "tipo arquivado é recusado MESMO com duration_minutos (que pula o lookup do tipo)" do
      ctx = setup_clinic()
      Directory.archive_appointment_type!(ctx.tipo, tenant: ctx.clinic.id, actor: ctx.owner)

      assert {:error, %Ash.Error.Invalid{}} = schedule(ctx, %{duration_minutos: 30})
    end

    test "profissional inativo é recusado — e explicitamente, não por acidente" do
      ctx = setup_clinic()
      Directory.deactivate_professional!(ctx.prof, tenant: ctx.clinic.id, actor: ctx.owner)

      assert {:error, %Ash.Error.Invalid{} = erro} = schedule(ctx, %{})

      assert Enum.any?(erro.errors, &(Map.get(&1, :field) == :professional_id))
    end

    test "paciente inativo é recusado" do
      ctx = setup_clinic()
      Records.deactivate_patient!(ctx.paciente, tenant: ctx.clinic.id, actor: ctx.owner)

      assert {:error, %Ash.Error.Invalid{} = erro} = schedule(ctx, %{})

      assert Enum.any?(erro.errors, &(Map.get(&1, :field) == :patient_ids))
    end

    test "agendamento JÁ CRIADO continua válido depois de arquivar o tipo" do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})

      Directory.archive_appointment_type!(ctx.tipo, tenant: ctx.clinic.id, actor: ctx.owner)
      Directory.deactivate_professional!(ctx.prof, tenant: ctx.clinic.id, actor: ctx.owner)
      Records.deactivate_patient!(ctx.paciente, tenant: ctx.clinic.id, actor: ctx.owner)

      # Não revalidamos o passado: a agenda de ontem não pode sumir porque o catálogo mudou.
      assert %{id: id} = Scheduling.get_appointment!(appt.id, scope: ctx.scope)
      assert id == appt.id
      assert [_] = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: ctx.scope)
    end
  end

  # A trilha deixou de ser uma tabela de versões por recurso (`AshPaperTrail`) e passou a ser
  # `audit_events` — uma linha por evento de qualquer um dos doze recursos (doc 63). O grosso do
  # que este bloco afirmava mudou de casa para `test/api/audit/audit_log_test.exs`; o que fica
  # aqui é o que é sobre o AGENDAMENTO: que agendar deixa rastro com ação e autor, e que o
  # participante deixa o seu.
  describe "trilha de auditoria (A-D6c)" do
    test "criar um agendamento grava um evento com a ação e o autor" do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})

      %{entries: entries} =
        Api.Audit.list_events(ctx.scope, resource: :appointment, record_id: appt.id)

      assert [evento] = entries
      assert evento.action == "schedule"
      assert evento.action_type == :create
      assert evento.actor.id == ctx.owner.id
    end

    # Quem entra numa turma que já existe deixa o seu — e é a única linha que diz QUEM entrou (a
    # do bloco, "Adicionou um participante", não nomeia ninguém). Já a presença que NASCE com o
    # bloco não é evento próprio: "Criou o agendamento" conta o mesmo fato e já mostra a turma, e
    # as duas linhas saíam no mesmo instante, dizendo a mesma coisa.
    test "o participante que entra depois gera evento; o que nasce com o bloco, não (A-D14)" do
      ctx = setup_clinic()
      turma = grupo_tipo(ctx, 4)
      {:ok, appt} = schedule(ctx, %{appointment_type_id: turma.id})

      assert %{entries: []} = Api.Audit.list_events(ctx.scope, resource: :attendance)

      entrou = novo_paciente(ctx)

      {:ok, _} =
        Scheduling.add_appointment_participants(appt, %{patient_ids: [entrou.id]},
          scope: ctx.scope
        )

      %{entries: entries} = Api.Audit.list_events(ctx.scope, resource: :attendance)
      assert [evento] = entries
      assert evento.action == "create"
      assert evento.patient.id == entrou.id
    end
  end

  # ---- Ciclo de vida (Entrega 4) ----

  defp scope_at(user, clinic, %DateTime{} = now) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership, now: now)
  end

  # O bloco recém-criado, para as transições. `now` fixa o relógio do escopo (ADR-009) para as
  # regras temporais serem determinísticas.
  defp agendado(ctx) do
    {:ok, appt} = schedule(ctx, %{})
    appt
  end

  describe "remarcar (:reschedule)" do
    test "move o horário e preserva a duração, avançando a versão" do
      ctx = setup_clinic()
      appt = agendado(ctx)

      assert {:ok, movido} =
               Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{
                 starts_at: at("09:00")
               })

      assert DateTime.compare(movido.starts_at, at("09:00")) == :eq
      # Duração de 50 min preservada (não relê o catálogo).
      assert DateTime.diff(movido.ends_at, movido.starts_at, :minute) == 50
      assert movido.version == appt.version + 1
    end

    test "GAP-03 corrigido: remarcar para fora do expediente é recusado (422 com code)" do
      ctx = setup_clinic()
      appt = agendado(ctx)

      # 12:30 cai no almoço (12:00–13:00 fechado no seed): o formulário já recusava; o arraste
      # passava reto no protótipo. Agora recusa igual.
      assert {:error, error} =
               Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{
                 starts_at: at("12:30")
               })

      assert "outside_business_hours" in codes(error)
    end

    test "remarcar para cima de outro bloco é recusado pela constraint (422, não 500)" do
      ctx = setup_clinic()
      {:ok, _fixo} = schedule(ctx, %{starts_at: at("09:00")})
      appt = agendado(ctx)

      # A constraint devolve InvalidAttribute na `:starts_at` com a mensagem única; o `code`
      # estável `schedule_conflict` é promovido na fronteira HTTP (ver o teste do controller).
      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{
                 starts_at: at("09:00")
               })
    end

    test "remarcar como encaixe fura o conflito (A-D2/A5)" do
      ctx = setup_clinic()
      {:ok, _fixo} = schedule(ctx, %{starts_at: at("09:00")})
      appt = agendado(ctx)

      assert {:ok, movido} =
               Scheduling.transition_appointment(ctx.scope, appt.id, :reschedule, %{
                 starts_at: at("09:00"),
                 encaixe: true
               })

      assert movido.encaixe == true
      assert DateTime.compare(movido.starts_at, at("09:00")) == :eq
    end
  end

  # A2 (doc 41): o desfecho é da PRESENÇA. O helper resolve a presença do bloco para os testes
  # que exercitam concluir/faltar/justificar — as ações de bloco foram aposentadas.
  defp presenca_de(ctx, appt) do
    Scheduling.list_attendances!(scope: ctx.scope, query: [filter: [appointment_id: appt.id]])
    |> hd()
  end

  describe "presença: concluir / faltar (gated por 'começou', D-E4.1)" do
    test "concluir antes da sessão começar é recusado" do
      ctx = setup_clinic()
      appt = agendado(ctx)
      # Relógio 1h ANTES do início.
      scope = scope_at(ctx.owner, ctx.clinic, DateTime.add(at("08:00"), -3600, :second))

      assert {:error, :session_not_started} =
               Scheduling.transition_participant(
                 scope,
                 appt.id,
                 presenca_de(ctx, appt).patient_id,
                 :complete
               )
    end

    # D-J: a transição não pode reler as presenças DEPOIS do commit. O teto pega a volta do
    # round-trip (medido: 18 → 14 queries num `complete`, e 4 → 3 toques na tabela de
    # presenças), sem cravar o número exato, que muda com refactor legítimo.
    test "a transição não relê as presenças depois do commit (D-J)" do
      ctx = setup_clinic()
      appt = agendado(ctx)
      scope = scope_at(ctx.owner, ctx.clinic, DateTime.add(at("08:00"), 3600, :second))

      pid = presenca_de(ctx, appt).patient_id

      {resultado, toques} =
        Api.QueryCounter.count(
          fn -> Scheduling.transition_participant(scope, appt.id, pid, :complete) end,
          "attendances"
        )

      assert {:ok, concluido} = resultado
      # O bloco sai daqui pronto para serializar — é isso que a releitura fazia.
      assert [%{status: :concluida}] = concluido.attendances

      # O caminho por presença lê a presença, escreve nela e relê para o rollup — o teto é maior
      # que o do bloco (3), e o que ele guarda é o mesmo: releitura pós-commit não volta.
      assert toques <= 6,
             "#{toques} toques na tabela de presenças: a releitura pós-commit voltou?"
    end

    test "concluir depois de começar seta o bloco e as presenças" do
      ctx = setup_clinic()
      appt = agendado(ctx)
      scope = scope_at(ctx.owner, ctx.clinic, DateTime.add(at("08:00"), 3600, :second))

      assert {:ok, concluido} =
               Scheduling.transition_participant(
                 scope,
                 appt.id,
                 presenca_de(ctx, appt).patient_id,
                 :complete
               )

      assert concluido.status == :concluido
      assert [%{status: :concluida}] = Scheduling.list_attendances!(scope: ctx.scope)
    end

    test "faltar incrementa o agregado de faltas do paciente; justificar zera; reabrir também" do
      ctx = setup_clinic()
      appt = agendado(ctx)
      scope = scope_at(ctx.owner, ctx.clinic, DateTime.add(at("08:00"), 3600, :second))

      pid = presenca_de(ctx, appt).patient_id

      {:ok, _} = Scheduling.transition_participant(scope, appt.id, pid, :no_show)
      assert faltas(ctx) == 1

      {:ok, just} =
        Scheduling.transition_participant(scope, appt.id, pid, :justify, %{justificada: true})

      assert faltas(ctx) == 0
      # A serialização carrega a justificativa NA PRESENÇA (o campo de bloco saiu com a A2).
      assert [%{falta_justificada: true}] = ApiWeb.AgendaJSON.appointment(just).participants

      {:ok, reaberto} = Scheduling.transition_participant(scope, appt.id, pid, :reopen)
      assert reaberto.status == :agendado

      assert [%{status: :prevista, falta_justificada: false}] =
               Scheduling.list_attendances!(scope: ctx.scope)

      assert faltas(ctx) == 0
    end
  end

  # F4 (doc 34): o servidor recusa transição a partir de um status de origem inválido — a UI só
  # mostra o botão certo, mas uma chamada direta à API não pode driblar a máquina de estados.
  describe "guard de status de origem (F4)" do
    test "reabrir um bloco JÁ agendado é recusado (não vira no-op com trilha fantasma)" do
      ctx = setup_clinic()
      appt = agendado(ctx)

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.transition_appointment(ctx.scope, appt.id, :reopen)
    end

    test "justificar presença que nunca faltou é recusado" do
      ctx = setup_clinic()
      appt = agendado(ctx)

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.transition_participant(
                 ctx.scope,
                 appt.id,
                 presenca_de(ctx, appt).patient_id,
                 :justify,
                 %{justificada: true}
               )
    end

    test "cancelar um bloco JÁ concluído é recusado (concluído → cancelado inválido)" do
      ctx = setup_clinic()
      appt = agendado(ctx)
      scope = scope_at(ctx.owner, ctx.clinic, DateTime.add(at("08:00"), 3600, :second))

      {:ok, concluido} =
        Scheduling.transition_participant(
          scope,
          appt.id,
          presenca_de(ctx, appt).patient_id,
          :complete
        )

      assert concluido.status == :concluido

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.transition_appointment(scope, appt.id, :cancel)

      # e o status permanece concluído.
      assert %{status: :concluido} = Scheduling.get_appointment!(appt.id, scope: scope)
    end

    test "marcar presença num bloco cancelado é recusado (block_not_open)" do
      ctx = setup_clinic()
      appt = agendado(ctx)
      pid = presenca_de(ctx, appt).patient_id
      {:ok, _} = Scheduling.transition_appointment(ctx.scope, appt.id, :cancel)
      scope = scope_at(ctx.owner, ctx.clinic, DateTime.add(at("08:00"), 3600, :second))

      assert {:error, :block_not_open} =
               Scheduling.transition_participant(scope, appt.id, pid, :complete)
    end
  end

  # Excluir é soft-delete (doc 40): o registro SOME das leituras (agenda, relatório, fila) mas
  # a linha e a trilha continuam — é para lançamento feito por engano, distinto de cancelar (que
  # aconteceu e conta). O que só o banco prova (o slot liberar) tem teste próprio abaixo, no
  # bloco da constraint.
  describe "excluir (soft-delete)" do
    test "excluir some com o bloco das leituras mas preserva a linha e a trilha" do
      ctx = setup_clinic()
      appt = agendado(ctx)

      assert {:ok, excluido} = Scheduling.transition_appointment(ctx.scope, appt.id, :exclude)
      assert excluido.excluded_at != nil

      # Sumiu da leitura da janela...
      assert Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: ctx.scope) == []

      # ...e da leitura por id (o fetch da própria transição volta not_found).
      assert {:error, :not_found} =
               Scheduling.transition_appointment(ctx.scope, appt.id, :reopen)

      # ...mas a LINHA continua no banco (soft-delete, não DELETE)...
      assert %{rows: [[stamp]]} =
               Api.Repo.query!("SELECT excluded_at FROM appointments WHERE id = $1", [
                 Ecto.UUID.dump!(appt.id)
               ])

      refute is_nil(stamp)

      # ...e a trilha registrou o "excluir" (o evento sobrevive; a tela de auditoria o lê).
      assert %{rows: [[n]]} =
               Api.Repo.query!(
                 "SELECT count(*) FROM audit_events WHERE record_id = $1 AND action = 'exclude'",
                 [Ecto.UUID.dump!(appt.id)]
               )

      assert n == 1
    end

    test "excluir um bloco cancelado é permitido (o caso mais comum: 'foi engano, some')" do
      ctx = setup_clinic()
      appt = agendado(ctx)
      {:ok, _} = Scheduling.transition_appointment(ctx.scope, appt.id, :cancel)

      assert {:ok, excluido} = Scheduling.transition_appointment(ctx.scope, appt.id, :exclude)
      assert excluido.excluded_at != nil
    end

    test "excluir um bloco JÁ concluído é recusado (aconteceu — reabra antes, F4)" do
      ctx = setup_clinic()
      appt = agendado(ctx)
      scope = scope_at(ctx.owner, ctx.clinic, DateTime.add(at("08:00"), 3600, :second))

      {:ok, _} =
        Scheduling.transition_participant(
          scope,
          appt.id,
          presenca_de(ctx, appt).patient_id,
          :complete
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.transition_appointment(scope, appt.id, :exclude)
    end

    test "excluir um bloco que faltou é recusado (a falta conta; não some da história)" do
      ctx = setup_clinic()
      appt = agendado(ctx)
      scope = scope_at(ctx.owner, ctx.clinic, DateTime.add(at("08:00"), 3600, :second))

      {:ok, _} =
        Scheduling.transition_participant(
          scope,
          appt.id,
          presenca_de(ctx, appt).patient_id,
          :no_show
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Scheduling.transition_appointment(scope, appt.id, :exclude)
    end

    test "expected_version obsoleto → {:error, :version_conflict}" do
      ctx = setup_clinic()
      appt = agendado(ctx)

      assert {:error, :version_conflict} =
               Scheduling.transition_appointment(
                 ctx.scope,
                 appt.id,
                 :exclude,
                 %{},
                 appt.version + 99
               )
    end

    test "recepção pode excluir (não é privilégio de owner/admin — decisão do doc 40)" do
      ctx = setup_clinic()
      appt = agendado(ctx)

      scope = escopo_de_membro!(ctx, :recepcao)

      assert {:ok, excluido} = Scheduling.transition_appointment(scope, appt.id, :exclude)
      assert excluido.excluded_at != nil
    end
  end

  describe "cancelar e locking otimista (409)" do
    test "cancelar preserva o registro com o motivo" do
      ctx = setup_clinic()
      appt = agendado(ctx)

      assert {:ok, cancelado} =
               Scheduling.transition_appointment(ctx.scope, appt.id, :cancel, %{
                 cancel_reason: "paciente pediu"
               })

      assert cancelado.status == :cancelado
      assert cancelado.cancel_reason == "paciente pediu"
    end

    test "expected_version obsoleto → {:error, :version_conflict}" do
      ctx = setup_clinic()
      appt = agendado(ctx)

      assert {:error, :version_conflict} =
               Scheduling.transition_appointment(
                 ctx.scope,
                 appt.id,
                 :cancel,
                 %{},
                 appt.version + 99
               )
    end

    test "id fora do tenant → {:error, :not_found}" do
      ctx = setup_clinic()

      assert {:error, :not_found} =
               Scheduling.transition_appointment(ctx.scope, Ash.UUID.generate(), :cancel)
    end
  end

  describe "A7 na escrita do ciclo de vida" do
    test "profissional não remarca para a coluna de um colega (403)" do
      ctx = setup_clinic()

      colega =
        Directory.create_professional!("Dr. Colega", %{tel: Api.Generators.telefone_unico()},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      appt = agendado(ctx)

      scope = escopo_de_membro!(ctx, :profissional, ctx.prof.id)

      assert {:error, %Ash.Error.Forbidden{}} =
               Scheduling.transition_appointment(scope, appt.id, :reschedule, %{
                 starts_at: at("09:00"),
                 professional_id: colega.id
               })
    end
  end

  # A fronteira do `:in_range` é semi-aberta dos dois lados: `[from, to)` contra
  # `[starts_at, ends_at)`. A ação promete sobreposição, não contenção ("um bloco que começa 07:50
  # e termina 08:40 pertence ao dia pedido mesmo que a janela comece 08:00").
  #
  # Nada testava isso. Descoberto por mutação no bate-volta: trocar a inclusividade das bordas
  # atravessava os 743 testes sem uma falha — porque toda chamada de `list_appointments!` do
  # arquivo usa janela larga (00:00–23:00), onde fronteira nunca morde. Estes três testes existem
  # para que a próxima reescrita do predicado tenha rede.
  # A duração positiva era invariante só de APLICAÇÃO (`min: 5` no tipo e no override). Quem
  # escreve por fora da ação — `Ash.Seed`, script de manutenção, INSERT à mão — passava direto,
  # e um bloco degenerado (`ends_at == starts_at`) é pior que um erro: ele SOME de qualquer
  # leitura por sobreposição de range, porque `tsrange(s, s, '[)')` é o range vazio e vazio não
  # sobrepõe nada. Achado do bate-volta; fechado no banco enquanto a tabela ainda está limpa.
  describe "duração positiva — invariante de banco" do
    test "bloco de duração zero é recusado pelo BANCO, não só pela ação" do
      ctx = setup_clinic()

      # O `check_constraints` no recurso é o que transforma a violação crua do Postgres num erro
      # de campo do Ash (422), em vez de deixar o Postgrex subir como 500.
      erro =
        assert_raise Ash.Error.Invalid, fn ->
          Ash.Seed.seed!(
            Api.Scheduling.Appointment,
            %{
              starts_at: at("08:00"),
              ends_at: at("08:00"),
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

      assert Exception.message(erro) =~ "duração precisa ser positiva"
      assert [%Ash.Error.Changes.InvalidAttribute{field: :ends_at}] = erro.errors
    end

    test "bloco invertido (ends_at antes de starts_at) também é recusado" do
      ctx = setup_clinic()

      assert_raise Ash.Error.Invalid, fn ->
        Ash.Seed.seed!(
          Api.Scheduling.Appointment,
          %{
            starts_at: at("09:00"),
            ends_at: at("08:00"),
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
    end
  end

  # O outro lado da mesma moeda (A2, doc 36 §6.2). O teto de 8h existe nas duas fontes de duração
  # (`AppointmentType.duracao_minutos` e o override `duration_minutos`, ambos `max: 480`), mas
  # também só na APLICAÇÃO. O `:in_range` passou a **depender** desse teto para poder cortar por
  # baixo (`starts_at > from − 8h`): sem a garantia no banco, uma linha de 10h escrita por fora da
  # ação ficaria invisível na leitura — sem erro, sem log, sem nada. O CHECK é o que torna o corte
  # legítimo; por isso os dois andam juntos e não em commits separados.
  describe "teto de duração — invariante de banco" do
    test "bloco de 8h01 é recusado pelo BANCO" do
      ctx = setup_clinic()

      erro =
        assert_raise Ash.Error.Invalid, fn ->
          Ash.Seed.seed!(
            Api.Scheduling.Appointment,
            %{
              starts_at: at("08:00"),
              ends_at: DateTime.add(at("08:00"), 8 * 3600 + 60, :second),
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

      assert Exception.message(erro) =~ "não pode passar de 8 horas"
      assert [%Ash.Error.Changes.InvalidAttribute{field: :ends_at}] = erro.errors
    end

    # O CHECK vive no banco (via migration) e a constante vive no Elixir. Mudar `Duration` sem
    # gerar migration não quebra compilação nem nenhum outro teste — quebra a premissa do corte do
    # `:in_range`, em silêncio. Este teste é a única coisa que amarra os dois lados.
    test "a constante do Elixir e o CHECK do banco falam o mesmo número" do
      %{rows: [[definicao]]} =
        Api.Repo.query!(
          "select pg_get_constraintdef(oid) from pg_constraint where conname = $1",
          ["appointments_duration_within_cap"]
        )

      horas = div(Api.Scheduling.Duration.max_minutos(), 60)
      minutos = rem(Api.Scheduling.Duration.max_minutos(), 60)

      esperado =
        "'#{String.pad_leading("#{horas}", 2, "0")}:#{String.pad_leading("#{minutos}", 2, "0")}:00'::interval"

      assert definicao =~ esperado,
             "o CHECK no banco é #{definicao}, mas Api.Scheduling.Duration diz #{Api.Scheduling.Duration.max_minutos()} min — falta migration?"
    end

    test "bloco de exatamente 8h passa — 480 min é duração legal" do
      ctx = setup_clinic()

      assert %{} =
               Ash.Seed.seed!(
                 Api.Scheduling.Appointment,
                 %{
                   starts_at: at("08:00"),
                   ends_at: at("16:00"),
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
  end

  describe ":in_range — fronteira da janela (semi-aberta)" do
    test "bloco que TERMINA exatamente no início da janela fica de fora" do
      ctx = setup_clinic()
      # 08:00–08:50 (tipo de 50 min)
      {:ok, _} = schedule(ctx, %{})

      assert [] == Scheduling.list_appointments!(at("08:50"), at("10:00"), scope: ctx.scope)
    end

    test "bloco que COMEÇA exatamente no fim da janela fica de fora" do
      ctx = setup_clinic()
      {:ok, _} = schedule(ctx, %{})

      assert [] == Scheduling.list_appointments!(at("07:00"), at("08:00"), scope: ctx.scope)
    end

    test "basta SOBREPOR a janela — não precisa estar contido nela" do
      ctx = setup_clinic()
      {:ok, appt} = schedule(ctx, %{})

      # janela começa no meio do bloco
      assert [a] = Scheduling.list_appointments!(at("08:30"), at("10:00"), scope: ctx.scope)
      assert a.id == appt.id

      # janela termina no meio do bloco
      assert [b] = Scheduling.list_appointments!(at("07:00"), at("08:30"), scope: ctx.scope)
      assert b.id == appt.id
    end

    # A rede do corte por baixo (A2). O bloco mais longo que o banco aceita (8h) tem de continuar
    # aparecendo quando a janela pega só o finalzinho dele — é o caso extremo que um bound errado
    # (`from − 4h`, ou o sinal trocado) apaga em silêncio. Seed e não `schedule/2` porque 08:00–16:00
    # atravessa o almoço do expediente padrão (12:00–13:00) e a ação recusaria por RN-14.
    test "bloco de 8h que só encosta o fim na janela continua aparecendo" do
      ctx = setup_clinic()

      appt =
        Ash.Seed.seed!(
          Api.Scheduling.Appointment,
          %{
            starts_at: at("08:00"),
            ends_at: at("16:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            status: :agendado,
            encaixe: true,
            version: 1,
            pkg_hold: false
          },
          tenant: ctx.clinic.id
        )

      assert [a] = Scheduling.list_appointments!(at("15:59"), at("17:00"), scope: ctx.scope)
      assert a.id == appt.id
    end

    # A preparation do corte roda mesmo com a query já inválida (é o default do Ash — é para isso
    # que existe `only_when_valid?`). Sem a cláusula de guarda ela quebraria por match failure e o
    # erro que o cliente veria seria esse, não o "argumento obrigatório" de verdade.
    test "sem o argumento `from`, o erro que volta é o do argumento — não um crash da preparation" do
      ctx = setup_clinic()

      assert {:error, %Ash.Error.Invalid{}} =
               Api.Scheduling.Appointment
               |> Ash.Query.for_read(:in_range, %{}, tenant: ctx.clinic.id, authorize?: false)
               |> Ash.read()
    end
  end

  describe "D-C — paginação do :in_range" do
    test "sem `page:` a lista inteira volta — os chamadores de hoje não mudam" do
      ctx = setup_clinic()
      for hhmm <- ~w(08:00 09:00 10:00), do: {:ok, _} = schedule(ctx, %{starts_at: at(hhmm)})

      assert [_, _, _] = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: ctx.scope)
    end

    # O teste acima, sozinho, não distingue "lista inteira" de "cortada em `default_limit`": com
    # 3 registros os dois mundos dão o mesmo resultado. Este fecha o buraco com 101 > 100.
    # `Ash.Seed` insere direto (rápido) e `encaixe: true` sai do predicado parcial da
    # `appointments_no_overlap`, então os 101 coexistem no mesmo horário — aqui importa a
    # CONTAGEM, não a geometria.
    test "sem `page:` NÃO trunca em default_limit — agenda não pode perder bloco em silêncio" do
      ctx = setup_clinic()

      for _ <- 1..101 do
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

      resultado = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: ctx.scope)

      assert is_list(resultado), "virou página: `required?: false` deixou de valer"

      assert length(resultado) == 101,
             "truncou em #{length(resultado)} — o default_limit vazou para quem não pediu página"
    end

    # Com offset? e keyset? ligados, o Ash só usa offset quando `offset:` vem junto — sem ele a
    # página volta como keyset. Os dois modos são exercitados: este e o `stream!` abaixo.
    test "com `page:` offset volta uma página limitada, contada e em ordem" do
      ctx = setup_clinic()
      for hhmm <- ~w(08:00 09:00 10:00), do: {:ok, _} = schedule(ctx, %{starts_at: at(hhmm)})

      assert %Ash.Page.Offset{results: [a, b], count: 3, more?: true} =
               Scheduling.list_appointments!(at("00:00"), at("23:00"),
                 scope: ctx.scope,
                 page: [limit: 2, offset: 0, count: true]
               )

      assert DateTime.compare(a.starts_at, b.starts_at) == :lt
    end

    # EMPATE é o ponto: com `starts_at` distinto o keyset funciona mesmo sem desempate, e o teste
    # passaria com `sort: [starts_at: :asc]` sozinho — não guardaria nada. Aqui um segundo
    # profissional duplica cada horário, então as fronteiras de página caem NO MEIO dos empates,
    # que é onde um cursor não-total pula ou repete linha.
    test "keyset: stream! atravessa as páginas sem pular nem repetir (o uso da Fatia 3)" do
      ctx = setup_clinic()

      colega =
        Directory.create_professional!("Dr. Y", %{tel: Api.Generators.telefone_unico()},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      for hhmm <- ~w(08:00 09:00 10:00) do
        {:ok, _} = schedule(ctx, %{starts_at: at(hhmm)})
        {:ok, _} = schedule(ctx, %{starts_at: at(hhmm), professional_id: colega.id})
      end

      ids =
        Scheduling.list_appointments!(at("00:00"), at("23:00"),
          scope: ctx.scope,
          stream?: true,
          stream_options: [batch_size: 2]
        )
        |> Enum.map(& &1.id)

      # 3 horários × 2 profissionais = 6, em 3 pares empatados; batch_size 2 corta dentro deles.
      assert length(ids) == 6, "o stream perdeu ou repetiu linha na fronteira da página"
      assert Enum.uniq(ids) == ids, "o stream repetiu linha entre páginas"

      lista = Scheduling.list_appointments!(at("00:00"), at("23:00"), scope: ctx.scope)
      assert MapSet.new(ids) == MapSet.new(Enum.map(lista, & &1.id))
    end
  end

  defp faltas(ctx) do
    Records.get_patient!(ctx.paciente.id, scope: ctx.scope, load: [:faltas]).faltas
  end

  # Bate-volta da Onda 3: `count_participants/2` — o `N` do `N/cap` que a validação de capacidade
  # usa — contava presença CANCELADA. Uma turma com vaga real recusava paciente.
  describe "o teto da turma conta só quem está de fato nela" do
    test "presença cancelada libera a vaga" do
      ctx = setup_clinic()
      tipo = grupo_tipo(ctx, 2)
      p1 = novo_paciente(ctx)
      p2 = novo_paciente(ctx)

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: tipo.id,
            patient_ids: [p1.id, p2.id]
          },
          scope: ctx.scope
        )

      assert Scheduling.count_participants(ctx.clinic.id, appt.id) == 2

      att =
        Scheduling.list_attendances!(scope: ctx.scope, query: [filter: [appointment_id: appt.id]])
        |> hd()

      Ash.update!(att, %{status: :cancelada},
        action: :transition,
        tenant: ctx.clinic.id,
        authorize?: false
      )

      assert Scheduling.count_participants(ctx.clinic.id, appt.id) == 1,
             "o teto ainda conta quem saiu"

      # e a vaga liberada aceita alguém de fato
      p3 = novo_paciente(ctx)

      assert {:ok, _} =
               Scheduling.schedule_appointment(
                 %{
                   starts_at: at("08:00"),
                   professional_id: ctx.prof.id,
                   appointment_type_id: tipo.id,
                   patient_ids: [p3.id]
                 },
                 scope: ctx.scope
               )
    end
  end
end
