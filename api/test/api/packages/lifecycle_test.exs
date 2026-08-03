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

  # O escopo de um usuário com papel `profissional` vinculado a uma coluna da agenda — o papel que
  # o recorte A7 (`OwnAgendaOnly`) filtra. O relógio é o mesmo `scope_before/1`: `escopo_de_membro!`
  # devolve o escopo com `now` real, e as sessões destes testes ficam em 2026-07, no passado.
  defp scope_profissional(ctx, professional_id) do
    s = escopo_de_membro!(ctx, :profissional, professional_id)
    {:ok, now} = Scheduling.LocalTime.to_utc(~D[2026-07-13], "08:00", "America/Sao_Paulo")
    Api.Scope.with_membership(s.user, s.membership, now: now)
  end

  # Uma sessão do MESMO pacote na coluna de OUTRO profissional. É estado atingível pelo produto:
  # `bulk_adjust(aplicar_profissional: true)` move as sessões do pacote entre colunas, e o `+` da
  # ficha agenda sessão nova escolhendo o profissional. Sexta 10:00 não colide com a grade
  # (segunda/quarta) da série.
  defp sessao_em_outra_coluna(ctx, pkg) do
    outra = profissional!(ctx, "Dr. Y #{unico()}")
    {:ok, sexta} = Scheduling.LocalTime.to_utc(~D[2026-07-24], "10:00", "America/Sao_Paulo")

    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: sexta,
          professional_id: outra.id,
          appointment_type_id: ctx.tipo.id,
          patient_ids: [ctx.paciente.id],
          package_id: pkg.id
        },
        scope: scope_before(ctx)
      )

    appt
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

    # Regressão (auditoria doc 96, B-1). CANCELAR o bloco não alcançava a presença segurada: a
    # `CascadeToAttendances` lia as presenças com `Ash.load!`, que passa pela preparation global
    # `HideHeldAttendances` (filtra `pkg_hold == false`). A cascata irmã `RemoveParticipants` abre
    # a porta com `set_context(%{include_held: true})`; esta não abria — assimetria entre duas
    # cascatas que precisam ver o MESMO conjunto.
    #
    # O estrago não parava no bloco cancelado. A presença ficava viva (`:prevista`, segurada)
    # pendurada num bloco `:cancelado`, e o `resume_package` não a recuperava: `held_targets/2`
    # rejeita bloco `:cancelado`, o par caía fora e `enqueue_reproject(…, 0)` não reprojetava
    # nada. Resultado para o paciente: **uma sessão paga desaparecia** do pacote, e a ficha
    # seguia desenhando a bolinha como "segurada" para sempre, num pacote `:ativo`.
    test "cancelar o bloco alcança a presença SEGURADA — a sessão paga não vira órfã" do
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

      # Pausar segura a presença do dono do pacote e deixa o bloco de pé (o colega continua).
      {:ok, _} = Packages.pause_package(scope_before(ctx), pkg.id)

      {:ok, _} = Scheduling.transition_appointment(scope_before(ctx), appt.id, :cancel)

      # Estado CRU: nenhuma presença do bloco pode ter sobrado viva.
      {:ok, %{rows: rows}} =
        Api.Repo.query(
          "SELECT at.status, at.pkg_hold FROM attendances at WHERE at.appointment_id = $1",
          [Ecto.UUID.dump!(appt.id)]
        )

      assert length(rows) == 2

      for [status, hold] <- rows do
        assert status == "cancelada",
               "presença sobrou #{status} (pkg_hold=#{hold}) num bloco cancelado"
      end
    end

    # Achado adversarial do bate-volta de 2026-07-26: com a presença segurada dentro, tirar o
    # COLEGA deixava o bloco `:agendado` com zero participantes visíveis — um bloco fantasma na
    # grade, ocupando o slot pela exclusion constraint e sem ninguém dentro. O guard do "último
    # participante" passou a contar a segurada como remanescente, e ela não aparece para ninguém.
    #
    # O conserto restaura a invariante que a pausa já tinha no caso individual: bloco cuja única
    # presença viva está segurada **é** bloco segurado.
    test "tirar o colega da turma faz o bloco entrar em hold junto — sem bloco fantasma" do
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

      {:ok, _} = Packages.pause_package(scope_before(ctx), pkg.id)

      {:ok, _} =
        Scheduling.remove_appointment_participants(appt, %{patient_ids: [colega.id]},
          scope: ctx.scope
        )

      # o bloco some da agenda (é só do pacote pausado agora), em vez de virar fantasma
      assert Scheduling.get_appointment(appt.id, scope: ctx.scope, not_found_error?: false) ==
               {:ok, nil}

      {:ok, %{rows: [[hold]]}} =
        Api.Repo.query("SELECT pkg_hold FROM appointments WHERE id = $1", [
          Ecto.UUID.dump!(appt.id)
        ])

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

  # O achado A3 (doc 101): o pacote pode ter sessões em mais de uma coluna da agenda — a massa move
  # (`bulk_adjust(aplicar_profissional:)`) e o `+` da ficha agenda onde quiser. Enquanto
  # `list_package_attendances/3` lia com `scope:` (`authorize?` ligado), a preparation
  # `OwnAgendaOnly` recortava as presenças pela coluna do ator; como TODO o resto do pacote deriva
  # os blocos a partir das presenças, o pacote inteiro se escondia de si mesmo para um
  # `:profissional`. Não é vazamento — o recorte fecha, não abre. É estado corrompido em silêncio.
  #
  # O conserto tem duas metades, e cada uma tem o seu teste aqui:
  #
  #   1. a **leitura** perdeu o recorte (é leitura do pacote, não da agenda de quem clicou);
  #   2. as **transições** do ciclo de vida saíram do alcance do papel `:profissional`, porque a
  #      escrita na sessão continua (deliberadamente) passando pela policy do `Appointment` — e
  #      cancelar um pacote espalhado esbarraria em `OwnProfessionalColumn` no meio do caminho.
  describe "pacote espalhado por mais de uma coluna (A3)" do
    @describetag :a3

    test "a trilha da ficha mostra o pacote INTEIRO, não só a coluna de quem olha" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      _na_outra_coluna = sessao_em_outra_coluna(ctx, pkg)

      trilha = Packages.list_sessions(scope_profissional(ctx, ctx.prof.id), pkg.id)

      assert length(trilha) == 5,
             "trilha recortada pelo A7: o cartão desenha #{length(trilha)} bolinhas ao lado de " <>
               "um contador `usadas` que sempre contou o pacote inteiro"
    end

    test "a âncora do `+1` é a última sessão do PACOTE, mesmo na coluna do colega" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      # a última sessão do pacote passa a ser a de sexta 24/07, na coluna do outro profissional;
      # as 4 da grade (seg/qua) terminam na quarta 22/07.
      _na_outra_coluna = sessao_em_outra_coluna(ctx, pkg)

      # o `+1` continua sendo do profissional (a policy só tirou dele as TRANSIÇÕES)
      assert {:ok, _} = Packages.add_session(scope_profissional(ctx, ctx.prof.id), pkg.id)
      Oban.drain_queue(queue: :housekeeping)

      # `sessoes/2` lê pelo escopo do owner (sem recorte) e vem ordenada por `starts_at`
      nova = ctx |> sessoes(pkg) |> List.last()
      {:ok, sexta} = Scheduling.LocalTime.to_utc(~D[2026-07-24], "10:00", "America/Sao_Paulo")

      assert DateTime.after?(nova.starts_at, sexta),
             "a sessão nova nasceu antes da última do pacote: `proxima_ancora/2` ancorou na " <>
               "última sessão da COLUNA do ator, não na do pacote"
    end

    test "cancelar por quem enxerga a clínica inteira alcança as duas colunas" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      _na_outra_coluna = sessao_em_outra_coluna(ctx, pkg)

      assert {:ok, cancelado} = Packages.cancel_package(scope_before(ctx), pkg.id)
      assert cancelado.status == :cancelado

      cruas = sessoes_cruas(pkg)
      assert length(cruas) == 5

      assert Enum.all?(cruas, &(&1.status == "cancelado")),
             "pacote marcado :cancelado com sessão viva: #{inspect(cruas)}"
    end

    test "arquivar recusa quando há sessão viva na coluna do colega" do
      ctx = setup_clinic()
      # sem materializar: a ÚNICA sessão do pacote nasce na coluna do outro profissional
      {:ok, pkg} = Packages.create_series(scope_before(ctx), params(ctx))
      _na_outra_coluna = sessao_em_outra_coluna(ctx, pkg)

      assert {:error, :sessoes_futuras} = Packages.archive_package(scope_before(ctx), pkg.id),
             "pacote arquivado com sessão viva na coluna do colega: `future_sessions/3` " <>
               "enxergou vazio por causa do recorte A7"
    end
  end

  describe "o ciclo de vida do pacote é de quem enxerga a clínica inteira (A3)" do
    @describetag :a3

    # `:profissional` fica de fora das quatro transições. As três saídas foram pesadas no doc 101
    # §4.1: recortar as sessões É o bug; escrever a sessão como cascata interna reabriria a porta
    # lateral que o bate-volta do `Bulk` fechou de propósito. Sobra tirar o papel da operação.
    setup do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      %{ctx: ctx, pkg: pkg, prof_scope: scope_profissional(ctx, ctx.prof.id)}
    end

    test "pausar recusa", %{pkg: pkg, prof_scope: scope} do
      assert {:error, %Ash.Error.Forbidden{}} = Packages.pause_package(scope, pkg.id)
    end

    test "cancelar recusa", %{pkg: pkg, prof_scope: scope} do
      assert {:error, %Ash.Error.Forbidden{}} = Packages.cancel_package(scope, pkg.id)
    end

    test "cancelar recusando não deixa sessão pela metade", %{pkg: pkg, prof_scope: scope} do
      {:error, _} = Packages.cancel_package(scope, pkg.id)

      cruas = sessoes_cruas(pkg)

      assert Enum.all?(cruas, &(&1.status == "agendado")),
             "a recusa cancelou sessão antes de parar — o ciclo de vida não é tudo-ou-nada: " <>
               "#{inspect(cruas)}"
    end

    # Faltou na primeira leva (doc 101 §4.1): `resume_package/2` também casava
    # `{:ok, _, _} = mark_package_active(...)`, então a recusa da policy virava `MatchError` — 500
    # no botão Retomar em vez do 403 que o caso é. É o mesmo defeito que `lifecycle/5` e
    # `archive_package/2` já tinham, na única das quatro transições que não passa por eles.
    test "retomar recusa — e recusa como erro, não como 500", %{
      ctx: ctx,
      pkg: pkg,
      prof_scope: scope
    } do
      {:ok, _} = Packages.pause_package(scope_before(ctx), pkg.id)

      assert {:error, %Ash.Error.Forbidden{}} = Packages.resume_package(scope, pkg.id)
    end

    test "arquivar recusa", %{ctx: ctx, prof_scope: scope} do
      # um pacote SEM sessão materializada, para que a recusa seja a da policy e não a de
      # `:sessoes_futuras` — que chega antes e esconderia o que este teste quer provar. Grade na
      # sexta para não colidir com a do `setup` (segunda/quarta), que já ocupou os slots.
      {:ok, vazio} =
        Packages.create_series(
          scope_before(ctx),
          params(ctx, %{
            grade: %{dows: [5], horarios: %{"5" => "15:00"}, professional_id: ctx.prof.id}
          })
        )

      assert {:error, %Ash.Error.Forbidden{}} = Packages.archive_package(scope, vazio.id)
    end

    test "o `+1` da ficha CONTINUA sendo do profissional", %{pkg: pkg, prof_scope: scope} do
      assert {:ok, _} = Packages.add_session(scope, pkg.id)
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

  # D1 (doc 69 §10): "concluído" é **ação manual**. Nada no sistema fecha o pacote sozinho — nem o
  # rollup da presença, nem o `restantes == 0`. É o `archive` que vira o status, e ele recusa
  # quando ainda há sessão futura de pé (senão sobra sessão viva num pacote fechado).
  describe "arquivar (D1)" do
    test "arquiva um pacote com todas as sessões resolvidas" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      # conclui as 4 sessões: nada de futuro sobra
      Enum.each(sessoes(ctx, pkg), fn appt ->
        {:ok, _} =
          Scheduling.transition_participant(
            scope_at(ctx, DateTime.add(appt.starts_at, 3600)),
            appt.id,
            ctx.paciente.id,
            :complete
          )
      end)

      assert {:ok, arquivado} = Packages.archive_package(scope_before(ctx), pkg.id)
      assert arquivado.status == :concluido
    end

    test "recusa quando ainda há sessão futura agendada" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      assert {:error, :sessoes_futuras} = Packages.archive_package(scope_before(ctx), pkg.id)
      assert Packages.get_package!(pkg.id, scope: ctx.scope).status == :ativo
    end

    test "recusa quando as futuras estão apenas SEGURADAS por uma pausa" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      {:ok, _} = Packages.pause_package(scope_before(ctx), pkg.id)

      assert {:error, :sessoes_futuras} = Packages.archive_package(scope_before(ctx), pkg.id)
    end

    test "recusa arquivar um pacote cancelado (estado terminal)" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      {:ok, _} = Packages.cancel_package(scope_before(ctx), pkg.id)

      assert {:error, :status_invalido} = Packages.archive_package(scope_before(ctx), pkg.id)
    end

    test "pacote CANCELADO não volta pelo `+` (D4)" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      {:ok, _} = Packages.cancel_package(scope_before(ctx), pkg.id)

      assert {:error, :status_invalido} = Packages.add_session(scope_before(ctx), pkg.id)
    end

    test "arquivar NÃO acontece sozinho ao zerar restantes (D1: é manual)" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      Enum.each(sessoes(ctx, pkg), fn appt ->
        {:ok, _} =
          Scheduling.transition_participant(
            scope_at(ctx, DateTime.add(appt.starts_at, 3600)),
            appt.id,
            ctx.paciente.id,
            :complete
          )
      end)

      recarregado = Packages.get_package!(pkg.id, scope: ctx.scope, load: [:restantes])
      assert recarregado.restantes == 0
      assert recarregado.status == :ativo, "o pacote se fechou sozinho — D1 diz que é manual"
    end
  end

  # O troco do ADR-011 (doc 69 §5c): não há renovação — o `total` é ajustável a qualquer momento,
  # para mais e para menos, sobre o MESMO pacote. Era a metade que nunca foi construída.
  describe "+1 sessão (ADR-011 / D4)" do
    test "soma ao total e materializa a sessão nova na próxima data da grade" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      antes = sessoes(ctx, pkg)

      assert {:ok, maior} = Packages.add_session(scope_before(ctx), pkg.id)
      assert maior.total == 5
      Oban.drain_queue(queue: :housekeeping)

      depois = sessoes(ctx, pkg)
      assert length(depois) == length(antes) + 1

      # a nova cai DEPOIS da última, no dia/horário da grade (seg 08:00 ou qua 09:00)
      ultima_antes = List.last(antes)
      nova = List.last(depois)
      assert DateTime.after?(nova.starts_at, ultima_antes.starts_at)
    end

    test "reabre um pacote arquivado (D4)" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      Enum.each(sessoes(ctx, pkg), fn appt ->
        {:ok, _} =
          Scheduling.transition_participant(
            scope_at(ctx, DateTime.add(appt.starts_at, 3600)),
            appt.id,
            ctx.paciente.id,
            :complete
          )
      end)

      {:ok, _} = Packages.archive_package(scope_before(ctx), pkg.id)

      assert {:ok, reaberto} = Packages.add_session(scope_before(ctx), pkg.id)
      assert reaberto.status == :ativo
      assert reaberto.total == 5
    end

    test "não passa do teto do recurso" do
      ctx = setup_clinic()
      {:ok, pkg} = Packages.create_series(scope_before(ctx), params(ctx, %{total: 120}))

      assert {:error, _} = Packages.add_session(scope_before(ctx), pkg.id)
    end

    # O `+1` materializa **antes** de somar ao total, e devolve o motivo quando não dá.
    #
    # Antes disto o total subia primeiro e o job vinha depois: com o slot ocupado, o job falhava em
    # silêncio (o Oban marcava sucesso) e o pacote ficava vendido com N+1 e com N na agenda — sem
    # erro na tela, sem linha de log, e a divergência só aparecendo quando o paciente cobrasse a
    # sessão que ninguém marcou.
    test "slot ocupado: recusa com o motivo e NÃO soma ao total" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      antes = sessoes(ctx, pkg)

      # A próxima data da grade depois da última sessão (seg 2026-08-03, 08:00) ocupada por outro
      # bloco do mesmo profissional — a exclusion constraint recusa, e `forcar` é falso aqui.
      outro = paciente!(ctx, "Bloqueio #{unico()}")
      {:ok, choque} = Scheduling.LocalTime.to_utc(~D[2026-08-03], "08:00", "America/Sao_Paulo")

      {:ok, _} =
        Scheduling.schedule_appointment(
          %{
            starts_at: choque,
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [outro.id]
          },
          scope: ctx.scope
        )

      assert {:error, _motivo} = Packages.add_session(scope_before(ctx), pkg.id)

      # O total continua o que foi vendido…
      assert Packages.get_package!(pkg.id, scope: ctx.scope).total == 4
      # …e nenhuma sessão a mais entrou (nem agora, nem por um job pendurado).
      Oban.drain_queue(queue: :housekeeping)
      assert length(sessoes(ctx, pkg)) == length(antes)
    end
  end

  describe "−1 sessão (D3: só futura, nunca o passado)" do
    test "cancela a ÚLTIMA sessão futura e diminui o total" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      antes = sessoes(ctx, pkg)
      ultima = List.last(antes)

      assert {:ok, menor} = Packages.remove_session(scope_before(ctx), pkg.id)
      assert menor.total == 3

      assert Scheduling.get_appointment!(ultima.id, scope: ctx.scope).status == :cancelado
    end

    test "RECUSA quando as sessões por resolver são todas passadas (o coração da D3)" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      # o relógio agora é DEPOIS da série inteira: nada de futuro sobrou, mas as sessões
      # continuam `:agendado` (ninguém as resolveu) — o estado sujo de uma clínica real
      {:ok, agora} = Scheduling.LocalTime.to_utc(~D[2026-09-01], "08:00", "America/Sao_Paulo")
      depois = scope_at(ctx, agora)

      assert {:error, :sem_sessao_futura} = Packages.remove_session(depois, pkg.id)

      # e nada foi cancelado atrás
      assert Enum.all?(sessoes_cruas(pkg), &(&1.status == "agendado"))
      assert Packages.get_package!(pkg.id, scope: ctx.scope).total == 4
    end

    test "não desce abaixo do que já foi consumido" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      # consome 3 das 4 e deixa 1 futura; o total não pode cair para menos que 3
      [a, b, c | _] = sessoes(ctx, pkg)

      Enum.each([a, b, c], fn appt ->
        {:ok, _} =
          Scheduling.transition_participant(
            scope_at(ctx, DateTime.add(appt.starts_at, 3600)),
            appt.id,
            ctx.paciente.id,
            :complete
          )
      end)

      assert {:ok, menor} = Packages.remove_session(scope_before(ctx), pkg.id)
      assert menor.total == 3

      assert {:error, :sem_sessao_futura} = Packages.remove_session(scope_before(ctx), pkg.id)
    end

    # Regressão do doc 96, B-13. O `−1` fazia duas escritas **sem transação**: cancelava a sessão
    # e só então baixava o total. Quando a segunda falha, a primeira fica — e a segunda tem um
    # jeito banal de falhar, que não é hipótese nenhuma: `total` tem `min: 1` no recurso, então
    # num pacote de UMA sessão o `set_package_total` recusa `0`.
    #
    # O estado que sobrava é o pior do domínio, e o próprio código o nomeia noutro lugar: "pacote
    # vendido com N sessões e zero na agenda". A recepção via 1 vendida, o paciente não tinha
    # nenhuma marcada, e nada no sistema dizia que houve um erro.
    test "recusa do total NÃO deixa a sessão cancelada para trás" do
      ctx = setup_clinic()

      {:ok, pkg} =
        Packages.create_series(
          scope_before(ctx),
          params(ctx, %{total: 1, nome: "Avulsa #{unico()}"})
        )

      Oban.drain_queue(queue: :housekeeping)

      [unica] = sessoes(ctx, pkg)

      # `min: 1` no `total` faz o segundo passo recusar. O primeiro já rodou.
      assert {:error, _} = Packages.remove_session(scope_before(ctx), pkg.id)

      assert Packages.get_package!(pkg.id, scope: ctx.scope).total == 1

      assert Scheduling.get_appointment!(unica.id, scope: ctx.scope).status == :agendado,
             "a sessão foi cancelada e o total não baixou — pacote vendido com 1, zero na agenda"
    end
  end

  # A trilha é a SÉRIE, não o cemitério dela. Sessão cancelada (pelo `−1`, pela massa, pela
  # reprojeção da retomada) sai da leitura — senão o cartão desenha 8 bolinhas num pacote de 6, e o
  # contador ao lado passa a discordar do desenho. É o filtro que o protótipo faz em `pkgSessions`
  # ([`:387`](../../../../interface/Movimento.dc.html#L387)).
  describe "trilha das sessões" do
    test "cancelada não entra na trilha" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      assert length(Packages.list_sessions(scope_before(ctx), pkg.id)) == 4

      {:ok, _} = Packages.remove_session(scope_before(ctx), pkg.id)

      trilha = Packages.list_sessions(scope_before(ctx), pkg.id)
      assert length(trilha) == 3
      refute Enum.any?(trilha, &(&1.estado == :cancelada))
    end

    test "a trilha em lote (o cartão da ficha) segue a mesma regra" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      {:ok, _} = Packages.remove_session(scope_before(ctx), pkg.id)

      atual = Packages.get_package!(pkg.id, scope: ctx.scope)
      por_pacote = Packages.sessions_by_package(scope_before(ctx), [atual])
      assert length(por_pacote[pkg.id]) == 3
    end

    test "segurada continua na trilha — pausar não apaga a série" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      {:ok, _} = Packages.pause_package(scope_before(ctx), pkg.id)

      trilha = Packages.list_sessions(scope_before(ctx), pkg.id)
      assert length(trilha) == 4
      assert Enum.all?(trilha, &(&1.estado == :segurada))
    end
  end

  describe "ajustar a grade (contrato 09:441)" do
    test "troca os dias da semana: as futuras saem das antigas e nascem nas novas" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      # de [seg, qua] para [ter]
      assert {:ok, _} =
               Packages.adjust_grade(scope_before(ctx), pkg.id, %{
                 dows: [2],
                 horarios: %{"2" => "10:00"},
                 professional_id: ctx.prof.id
               })

      Oban.drain_queue(queue: :housekeeping)

      vivas =
        sessoes(ctx, pkg)
        |> Enum.reject(&(&1.status == :cancelado))

      assert vivas != []

      assert Enum.all?(vivas, fn appt ->
               Date.day_of_week(
                 Scheduling.LocalTime.to_local_date(appt.starts_at, "America/Sao_Paulo")
               ) == 2
             end),
             "sobrou sessão fora da grade nova"

      # e a grade guardada é a nova (senão a próxima materialização volta ao passado)
      grade = Packages.get_package!(pkg.id, scope: ctx.scope, load: [:schedule]).schedule
      assert grade.dows == [2]
      assert grade.horarios == %{"2" => "10:00"}
    end

    test "usadas não muda — o que já aconteceu não se reescreve" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      primeira = hd(sessoes(ctx, pkg))

      {:ok, _} =
        Scheduling.transition_participant(
          scope_at(ctx, DateTime.add(primeira.starts_at, 3600)),
          primeira.id,
          ctx.paciente.id,
          :complete
        )

      {:ok, _} =
        Packages.adjust_grade(scope_before(ctx), pkg.id, %{
          dows: [2],
          horarios: %{"2" => "10:00"},
          professional_id: ctx.prof.id
        })

      assert Packages.get_package!(pkg.id, scope: ctx.scope, load: [:usadas]).usadas == 1
    end

    test "recusa num pacote pausado — retome antes de ajustar" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)
      {:ok, _} = Packages.pause_package(scope_before(ctx), pkg.id)

      assert {:error, :status_invalido} =
               Packages.adjust_grade(scope_before(ctx), pkg.id, %{
                 dows: [2],
                 horarios: %{"2" => "10:00"},
                 professional_id: ctx.prof.id
               })
    end

    test "grade vazia é recusada" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      assert {:error, _} =
               Packages.adjust_grade(scope_before(ctx), pkg.id, %{
                 dows: [],
                 horarios: %{},
                 professional_id: ctx.prof.id
               })
    end

    # As três abaixo cobrem o mesmo defeito medido no bate-volta: `adjust_grade` CANCELA as futuras
    # antes de saber se a grade nova consegue materializar. Quando o profissional escolhido não
    # serve, o job falha em silêncio (`Materializer.create_sessions` descarta o erro do
    # `Enum.each`) e o pacote fica **sem sessão nenhuma** — vendido com 4, zero na agenda.
    #
    # A recusa tem de vir ANTES do cancelamento; por isso cada teste confere as duas coisas: o
    # erro E as sessões ainda de pé.
    test "recusa profissional de OUTRA clínica — e não cancela as futuras" do
      ctx = setup_clinic()
      outra = setup_clinic()
      pkg = criar_e_materializar(ctx)

      assert {:error, :profissional_invalido} =
               Packages.adjust_grade(scope_before(ctx), pkg.id, %{
                 dows: [2],
                 horarios: %{"2" => "10:00"},
                 professional_id: outra.prof.id
               })

      Oban.drain_queue(queue: :housekeeping)

      vivas = Enum.reject(sessoes(ctx, pkg), &(&1.status == :cancelado))
      assert length(vivas) == 4, "o pacote perdeu sessões numa recusa"

      # e a grade não foi reescrita com a referência de outro tenant
      grade = Packages.get_package!(pkg.id, scope: ctx.scope, load: [:schedule]).schedule
      assert grade.professional_id == ctx.prof.id
    end

    test "recusa profissional INATIVO da própria clínica — e não cancela as futuras" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      outro =
        Api.Directory.create_professional!(
          "Fisio Arquivado",
          %{tel: Api.Generators.telefone_unico()},
          tenant: ctx.clinic.id,
          authorize?: false
        )

      Api.Directory.update_professional!(outro, %{ativo: false},
        tenant: ctx.clinic.id,
        authorize?: false
      )

      assert {:error, :profissional_inativo} =
               Packages.adjust_grade(scope_before(ctx), pkg.id, %{
                 dows: [2],
                 horarios: %{"2" => "10:00"},
                 professional_id: outro.id
               })

      Oban.drain_queue(queue: :housekeeping)

      vivas = Enum.reject(sessoes(ctx, pkg), &(&1.status == :cancelado))
      assert length(vivas) == 4, "o pacote perdeu sessões numa recusa"
    end

    # Sem `professional_id` no corpo a grade mantém o que já tinha — mas "o que já tinha" pode ter
    # sido arquivado desde então, e aí o buraco é o mesmo. Vale o profissional EFETIVO, não o que
    # veio do corpo.
    test "recusa quando o profissional que FICA na grade foi arquivado" do
      ctx = setup_clinic()
      pkg = criar_e_materializar(ctx)

      Api.Directory.update_professional!(ctx.prof, %{ativo: false},
        tenant: ctx.clinic.id,
        authorize?: false
      )

      assert {:error, :profissional_inativo} =
               Packages.adjust_grade(scope_before(ctx), pkg.id, %{
                 dows: [2],
                 horarios: %{"2" => "10:00"}
               })

      Oban.drain_queue(queue: :housekeeping)

      vivas = Enum.reject(sessoes(ctx, pkg), &(&1.status == :cancelado))
      assert length(vivas) == 4, "o pacote perdeu sessões numa recusa"
    end

    # O mesmo furo pela porta da criação: lá o sintoma era `MatchError` dentro do `Preview`
    # (500 no controller), em vez de uma recusa limpa.
    test "create_series recusa profissional de OUTRA clínica sem estourar" do
      ctx = setup_clinic()
      outra = setup_clinic()

      assert {:error, :profissional_invalido} =
               Packages.create_series(
                 scope_before(ctx),
                 params(ctx, %{
                   grade: %{
                     dows: [1],
                     horarios: %{"1" => "08:00"},
                     professional_id: outra.prof.id
                   }
                 })
               )
    end
  end

  # A-6 do doc 42, que ficou "para a etapa que reabrir o ciclo de vida do pacote" — é esta.
  describe "corrida: pausar ANTES de o job materializar (A-6)" do
    test "o job materializa já SEGURANDO quando o pacote está pausado" do
      ctx = setup_clinic()
      # cria (enfileira o job) e pausa dentro da janela, antes de o Oban rodar
      {:ok, pkg} = Packages.create_series(scope_before(ctx), params(ctx))
      {:ok, pausado} = Packages.pause_package(scope_before(ctx), pkg.id)
      assert pausado.status == :pausado

      Oban.drain_queue(queue: :housekeeping)

      cruas = sessoes_cruas(pkg)
      assert length(cruas) == 4

      assert Enum.all?(cruas, & &1.pkg_hold),
             "o job criou sessões VISÍVEIS num pacote pausado (A-6)"

      # e a agenda não as mostra (RN-05)
      assert [] == sessoes(ctx, pkg)
    end
  end
end
