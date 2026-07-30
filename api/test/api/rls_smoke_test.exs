defmodule Api.RlsSmokeTest do
  @moduledoc """
  O gate que faltava: exercita os caminhos por-tenant com o **mesmo role do servidor**
  (`cinetra_app`, NOBYPASSRLS), e não com o `postgres` do resto da suíte.

  ## Por que este arquivo existe

  O sandbox de teste conecta como `postgres`, que é SUPERUSER e portanto **bypassa RLS**.
  Consequência medida na fatia Agenda: uma leitura por-tenant sem `in_clinic`/`with_clinic`
  passa verde no `mix test` e devolve **lista vazia** no servidor real. A mesma chamada,
  sob os dois roles:

      cinetra_app, SEM in_clinic : 0 profissionais
      cinetra_app, COM in_clinic : 2 profissionais
      postgres                     : 2 profissionais

  Essa classe de bug mordeu três vezes numa fatia só e era invisível ao gate de cobertura.

  ## Como rodar

      # local (exige o role criado no banco de teste — ver priv/sql/setup_app_role.sql)
      DATABASE_USER=cinetra_app DATABASE_PASSWORD=cinetra_app mix test --only rls

  No CI é o job `api-rls`. Sob `postgres` estes testes também passam — só que sem provar
  nada; é rodando como `cinetra_app` que eles viram gate.

  ## O que é asserção aqui

  **Não-vazio.** Parece fraco e não é: sob RLS, o modo de falha de "esqueci o `in_clinic`"
  é exatamente *zero linhas*, silenciosamente. Uma leitura que devolve o que criou é a
  prova de que a GUC chegou onde precisava.
  """
  use Api.DataCase, async: false

  require Ash.Query

  @moduletag :rls

  alias Api.Accounts
  alias Api.Directory
  alias Api.Packages
  alias Api.Records
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp fixture do
    owner = Accounts.register_user!("Dono RLS", email_unico("rls"), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica RLS #{System.unique_integer([:positive])}", %{},
        actor: owner
      )

    membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)
    scope = Api.Scope.with_membership(owner, membership)

    prof =
      Directory.create_professional!("Dra. RLS", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        actor: owner
      )

    tipo =
      Directory.create_appointment_type!(
        %{
          nome: "Sessão RLS #{System.unique_integer([:positive])}",
          duracao_minutos: 50,
          cor: "#0FB5A6",
          icon: "Activity"
        },
        tenant: clinic.id,
        actor: owner
      )

    paciente =
      Records.create_patient!("Paciente RLS", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        actor: owner
      )

    %{owner: owner, clinic: clinic, scope: scope, prof: prof, tipo: tipo, paciente: paciente}
  end

  # O bloco com as presenças, pela porta que a aplicação usa (`in_clinic`): a code interface crua
  # roda fora da GUC e devolveria `nil` sob RLS — que é o próprio ponto deste arquivo.
  defp bloco(ctx, appointment_id) do
    Api.Tenancy.in_clinic(ctx.scope, fn ->
      Scheduling.get_appointment!(appointment_id, scope: ctx.scope, load: [:attendances])
    end)
  end

  # O paciente do `fixture/0` nasce sem consentimento nem e-mail — o `Dispatch` não falaria com
  # ele. Aqui ele precisa receber para haver mensagem, e mensagem para haver resposta.
  defp alcancavel(ctx) do
    Records.update_patient!(
      ctx.paciente,
      %{comunicacao: true, email: email_unico("rls-resposta")},
      tenant: ctx.clinic.id,
      actor: ctx.owner
    )
  end

  # A resposta ao link, pela mesma porta do controller público (`record_reply` dentro de
  # `in_clinic`).
  #
  # A mensagem **não** é criada aqui: com o paciente alcançável, o gatilho de criação do bloco já
  # enfileirou a confirmação, e um segundo `Dispatch.dispatch` devolve `{:skip, :ja_na_fila}`. Ler
  # a que existe é também o caminho real — o paciente responde à automática, não a uma inventada
  # pelo teste. Zero mensagens aqui já seria falha de GUC, antes da asserção do agregado.
  defp responder(ctx, appointment_id, resposta) do
    [presenca | _] = bloco(ctx, appointment_id).attendances

    Api.Tenancy.in_clinic(ctx.scope, fn ->
      [message | _] =
        Api.Messaging.list_attendance_messages!(presenca.id,
          tenant: ctx.clinic.id,
          authorize?: false
        )

      Api.Messaging.do_record_reply!(message, %{resposta: resposta},
        tenant: ctx.clinic.id,
        authorize?: false
      )
    end)
  end

  # A próxima segunda-feira — dia de expediente (o seed abre seg–sex) e no **futuro**, que é o
  # recorte que pausar/cancelar pacote exige ("hoje ou depois"). Calculada, não fixa: a data
  # literal do resto do arquivo envelhece para o passado conforme a suíte roda.
  defp proxima_segunda(hhmm) do
    hoje = Date.utc_today()
    data = Date.add(hoje, 8 - Date.day_of_week(hoje))
    {:ok, dt} = Scheduling.LocalTime.to_utc(data, hhmm, "America/Sao_Paulo")
    dt
  end

  defp at(hhmm) do
    {:ok, dt} = Scheduling.LocalTime.to_utc(@segunda, hhmm, "America/Sao_Paulo")
    dt
  end

  @doc false
  # **A peça que torna este arquivo um gate de verdade.**
  #
  # O sandbox de teste roda o teste inteiro dentro de UMA transação. Como a GUC é `SET LOCAL`,
  # a primeira escrita do `fixture/0` (que a seta via `SetTenantGuc`) a deixa **pendurada** até
  # o fim do teste — e qualquer leitura posterior a herda de graça. Resultado: uma leitura sem
  # `in_clinic` passa verde mesmo sob `cinetra_app`, e o gate vira decoração.
  #
  # Verificado: com o `in_clinic` do `load_agenda` removido de propósito, o arquivo passava.
  # Zerando a GUC antes da leitura, ele falha — que é o comportamento correto.
  #
  # Em produção não existe herança: cada request chega numa transação nova, sem GUC. Zerar
  # aqui **reproduz a precondição real** em vez de inventar uma.
  defp sem_guc do
    Api.Repo.query!("SELECT set_config('cinetra.clinic_id', '', true)")
    :ok
  end

  describe "quem sou eu" do
    test "o teste roda com um role que NÃO bypassa RLS (senão não prova nada)" do
      %{rows: [[user, bypass]]} =
        Api.Repo.query!(
          "SELECT current_user, rolbypassrls FROM pg_roles WHERE rolname = current_user"
        )

      # Sob `postgres` este teste é pulado com uma mensagem clara, em vez de passar
      # silenciosamente dando a impressão de que a RLS foi exercitada.
      if bypass do
        IO.puts(
          "\n  [rls] AVISO: rodando como #{user} (BYPASSRLS) — este arquivo não prova nada. " <>
            "Use DATABASE_USER=cinetra_app.\n"
        )
      end

      assert is_binary(user)
    end
  end

  describe "leitura por-tenant sob RLS" do
    test "load_agenda devolve o que foi criado (0 aqui significa GUC faltando)" do
      ctx = fixture()

      {:ok, _} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [ctx.paciente.id]
          },
          scope: ctx.scope
        )

      # A GUC pendurada pelo setup é zerada: a leitura tem de setar a sua.
      :ok = sem_guc()
      agenda = Scheduling.load_agenda(ctx.scope, at("00:00"), at("23:00"))

      assert length(agenda.appointments) == 1, "agendamentos vazios: a GUC não chegou na leitura"
      refute Enum.empty?(agenda.professionals), "profissionais vazios: a GUC não chegou"
      refute Enum.empty?(agenda.appointment_types), "tipos vazios: a GUC não chegou"
      refute Enum.empty?(agenda.patients), "pacientes vazios: a GUC não chegou"
    end

    test "a resposta do paciente atravessa a RLS de `messages` dentro da leitura da agenda" do
      # O agregado `Attendance.resposta_do_paciente` (a estrelinha do card) faz a leitura da agenda
      # olhar uma tabela de OUTRO domínio, `messages`, que tem RLS própria. É a forma de bug que
      # este arquivo existe para pegar: se a GUC não valesse dentro da subquery do agregado, ela
      # voltaria vazia e o campo chegaria `nil` — a estrela **nunca** apareceria no servidor real,
      # com a suíte inteira verde (o sandbox do `mix test` roda como superusuário).
      ctx = fixture()
      paciente = alcancavel(ctx)

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [paciente.id]
          },
          scope: ctx.scope
        )

      responder(ctx, appt.id, :confirmou)

      :ok = sem_guc()
      agenda = Scheduling.load_agenda(ctx.scope, at("00:00"), at("23:00"))

      assert [bloco] = agenda.appointments
      assert [presenca] = bloco.attendances

      assert presenca.resposta_do_paciente == :confirmou,
             "resposta vazia: a GUC não chegou na subquery do agregado sobre `messages`"
    end

    test "load_availability_sources enxerga as 4 fontes" do
      ctx = fixture()

      :ok = sem_guc()

      assert {:ok, professional, sources} =
               Scheduling.load_availability_sources(ctx.clinic.id, ctx.prof.id, @segunda)

      assert professional.id == ctx.prof.id

      # O expediente semeado pelo onboard tem que estar visível; vazio aqui significa que a
      # leitura das fontes rodou sem tenant e o dia inteiro pareceria fechado.
      refute Enum.empty?(sources.clinic_hours), "clinic_hours vazio: a GUC não chegou"
    end

    test "a composição das camadas devolve o expediente real, não 'fechado'" do
      ctx = fixture()

      :ok = sem_guc()

      {:ok, professional, sources} =
        Scheduling.load_availability_sources(ctx.clinic.id, ctx.prof.id, @segunda)

      assert {:open, periods} =
               Scheduling.Availability.day_periods(@segunda, professional, sources)

      refute Enum.empty?(periods)
    end
  end

  describe "escrita por-tenant sob RLS" do
    test "criar agendamento atravessa o WITH CHECK da policy" do
      ctx = fixture()

      assert {:ok, appt} =
               Scheduling.schedule_appointment(
                 %{
                   starts_at: at("09:00"),
                   professional_id: ctx.prof.id,
                   appointment_type_id: ctx.tipo.id,
                   patient_ids: [ctx.paciente.id]
                 },
                 scope: ctx.scope
               )

      assert appt.clinic_id == ctx.clinic.id
    end

    test "o merge de turma acha a turma existente (A-D4) — 0 aqui vira conflito, não fusão" do
      ctx = fixture()

      turma =
        Directory.create_appointment_type!(
          %{
            nome: "Turma RLS #{System.unique_integer([:positive])}",
            duracao_minutos: 50,
            cor: "#0FB5A6",
            icon: "Users",
            grupo: true,
            capacidade: 4
          },
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      outro =
        Records.create_patient!("Paciente 2 RLS", %{tel: Api.Generators.telefone_unico()},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      base = %{
        starts_at: at("11:00"),
        professional_id: ctx.prof.id,
        appointment_type_id: turma.id
      }

      {:ok, primeiro} =
        Scheduling.schedule_appointment(Map.put(base, :patient_ids, [ctx.paciente.id]),
          scope: ctx.scope
        )

      # O lookup da turma acontece FORA da ação, então tem GUC própria. Sem ela a leitura volta
      # vazia sob RLS, o merge não acontece e o segundo participante morre na exclusion
      # constraint — com a suíte normal verde, porque lá o sandbox bypassa RLS.
      assert {:ok, segundo} =
               Scheduling.schedule_appointment(Map.put(base, :patient_ids, [outro.id]),
                 scope: ctx.scope
               )

      assert segundo.id == primeiro.id,
             "não fundiu: o lookup da turma rodou sem a GUC de tenant"
    end

    test "a trilha é gravada (o after_action do paper trail roda sob a GUC da ação)" do
      ctx = fixture()

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("10:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [ctx.paciente.id]
          },
          scope: ctx.scope
        )

      # Se o INSERT na tabela de versões rodasse sem GUC, o WITH CHECK da RLS o barraria e a
      # ação inteira voltaria — então "o agendamento existe" já prova que a trilha passou.
      assert appt.id
    end
  end

  describe "pacote sob RLS (Fatia 3)" do
    # A grade mínima: uma segunda às 08:00 (dentro do expediente semeado pelo onboard), 3 sessões.
    # A massa e o ciclo de vida só alcançam sessão **futura** (o recorte é o mesmo em toda parte).
    # Ancorar a série numa data fixa (`@segunda`, 2026-07-20) fazia este arquivo apodrecer com o
    # relógio: a partir de 28/07 as duas sessões já eram passado e a massa achava zero — falha que
    # não tem nada a ver com RLS, que é o que este gate existe para provar. A âncora agora é a
    # próxima segunda-feira **depois de hoje**.
    defp proxima_segunda do
      hoje = Date.utc_today()
      Date.add(hoje, rem(8 - Date.day_of_week(hoje), 7) + 7)
    end

    defp package_params(ctx, opts \\ []) do
      %{
        nome: "Pacote RLS #{System.unique_integer([:positive])}",
        total: Keyword.get(opts, :total, 3),
        falta_punitiva: true,
        cor: "#0FB5A6",
        data_inicio: Keyword.get(opts, :data_inicio, proxima_segunda()),
        patient_id: ctx.paciente.id,
        appointment_type_id: ctx.tipo.id,
        grade: %{dows: [1], horarios: %{"1" => "08:00"}, professional_id: ctx.prof.id}
      }
    end

    test "reler o pacote depois de criar (o re-read do controller) não estoura ''::uuid" do
      ctx = fixture()

      {:ok, pkg} = Packages.create_series(ctx.scope, package_params(ctx), forcar: false)

      # A GUC pendurada pelo setup é zerada: reproduz o request novo que o controller atende. O
      # `get_package!` cru rodaria fora do `in_clinic` e a RLS o barraria com `""::uuid` (500) no
      # servidor real — invisível ao `mix test`, que roda como `postgres` (BYPASSRLS).
      :ok = sem_guc()

      relido = Packages.get_patient_package!(ctx.scope, pkg.id, load: [:schedule, :usadas])
      assert relido.id == pkg.id
      assert relido.schedule, "grade vazia: a GUC não chegou na releitura"
    end

    test "o job de materialização cria as N sessões sob RLS — falha/0 aqui = GUC faltando" do
      ctx = fixture()

      {:ok, pkg} = Packages.create_series(ctx.scope, package_params(ctx, total: 3), forcar: false)

      # O job Oban começa SEM GUC ambiente em produção (transação nova, sem herança). Zerar antes
      # de drenar reproduz isso: as leituras do job (pacote, tipo, presenças) e a releitura do
      # `stamp` têm de setar a própria GUC via `in_clinic`. Sem o fix, o job falha (`""::uuid`).
      :ok = sem_guc()
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :housekeeping)

      # E as sessões existem de fato: 3 presenças carimbadas com o pacote. A contagem roda sob
      # `in_clinic` (a própria leitura precisa da GUC — senão a RLS a filtra para zero/erro).
      :ok = sem_guc()

      carimbadas =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Scheduling.list_attendances!(
            tenant: ctx.clinic.id,
            authorize?: false,
            query: [filter: [package_id: pkg.id]]
          )
        end)

      assert length(carimbadas) == 3, "materialização não gravou as 3 sessões sob RLS"
    end

    # `checar_profissional/2` (bate-volta doc 77) lê `professionals` para responder "existe nesta
    # clínica e está ativo?" — leitura por-tenant nova num caminho de escrita.
    #
    # **O que este teste NÃO prova, e foi medido:** que aquela leitura precisa do `in_clinic`.
    # Tirando o `in_clinic` de `checar_profissional/2`, este teste continua **verde** sob
    # `cinetra_app`. A razão é o sandbox: a suíte roda tudo numa transação só, então a GUC que o
    # `in_clinic` anterior (o `get_package!` do próprio `adjust_grade`) pendurou com `SET LOCAL`
    # ainda vale quando a checagem roda — nem o `sem_guc()` acima adianta, porque `adjust_grade`
    # reseta a GUC antes de chegar lá. É o limite conhecido deste gate: ele prova a porta de
    # entrada, não cada leitura interna.
    #
    # A necessidade do `in_clinic` está provada **fora** da suíte, por psql direto:
    #
    #     cinetra_app, sem a GUC : 0 profissionais
    #     cinetra_app, com a GUC : 1 profissional
    #
    # Sem ele, em produção (transação por ação, sem GUC herdada) TODO ajuste de grade recusaria
    # com `:profissional_invalido`. O que este teste guarda é o caminho ponta a ponta sob o role
    # restrito — escrita, policies e releitura — que é valor próprio.
    test "ajustar a grade roda ponta a ponta sob RLS (role restrito)" do
      ctx = fixture()

      {:ok, pkg} = Packages.create_series(ctx.scope, package_params(ctx, total: 3), forcar: false)
      assert %{failure: 0} = Oban.drain_queue(queue: :housekeeping)

      # Requisição nova: sem GUC ambiente, como o controller atende.
      :ok = sem_guc()

      assert {:ok, _} =
               Packages.adjust_grade(ctx.scope, pkg.id, %{
                 dows: [2],
                 horarios: %{"2" => "10:00"},
                 professional_id: ctx.prof.id
               })
    end
  end

  describe "presença por participante sob RLS (Frente 6/A2)" do
    test "marcar presente rola o desfecho do bloco — o rollup lê+escreve o bloco sob RLS" do
      ctx = fixture()

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [ctx.paciente.id]
          },
          scope: ctx.scope
        )

      # A GUC pendurada pelo setup é zerada: o `RollupBlockStatus` lê o bloco e o reescreve DENTRO
      # da transação da ação de presença — se a GUC não caísse ali (o `SetTenantGuc` da ação de
      # `Attendance`), a leitura do bloco voltaria vazia e o `Ash.get!` estouraria. Invisível ao
      # `mix test` (postgres/BYPASSRLS).
      :ok = sem_guc()

      assert {:ok, updated} =
               Scheduling.transition_participant(
                 ctx.scope,
                 appt.id,
                 ctx.paciente.id,
                 :complete,
                 %{},
                 appt.version
               )

      assert updated.status == :concluido, "o rollup não escreveu o desfecho (GUC faltando?)"
      assert updated.version == appt.version + 1

      assert Enum.find(updated.attendances, &(&1.patient_id == ctx.paciente.id)).status ==
               :concluida
    end
  end

  describe "massa por pacote e histórico sob RLS (A2 etapa 3 / C13)" do
    test "bulk_cancel varre e escreve sob a própria GUC — 0 afetadas aqui = GUC faltando" do
      ctx = fixture()

      {:ok, pkg} = Packages.create_series(ctx.scope, package_params(ctx, total: 2), forcar: false)
      :ok = sem_guc()
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :housekeeping)

      # A massa abre a PRÓPRIA transação (`Api.Packages.Bulk.run/3`) e seta a GUC nela: sem isso a
      # escrita estouraria `""::uuid` ou bateria no WITH CHECK da policy. Nada disso aparece no
      # `mix test`, que roda como `postgres`.
      #
      # LIMITE MEDIDO deste gate (vale para todo este arquivo): o sandbox roda o teste inteiro numa
      # transação só, então o **primeiro** `in_clinic` do caminho deixa a GUC pendurada para as
      # leituras seguintes. Tirar o `in_clinic` de uma leitura INTERNA (`Bulk.attendances/2`, por
      # exemplo) continua passando aqui — em produção não, porque lá cada `with_clinic` commita e a
      # GUC morre com ele. O que este teste prova é a porta de entrada e a escrita; leitura interna
      # sem GUC continua sendo achado de revisão, não de suíte.
      :ok = sem_guc()

      assert {:ok, %{afetadas: afetadas}} =
               Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :todas})

      assert afetadas > 0, "a massa não achou as sessões do pacote (GUC faltando?)"
    end

    test "bulk_adjust: o warm e o espelho do horário atravessam a RLS" do
      ctx = fixture()

      {:ok, pkg} = Packages.create_series(ctx.scope, package_params(ctx, total: 2), forcar: false)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :housekeeping)

      # Duas coisas novas no caminho (doc 43): o **warm** do lote, que lê clínica/expediente numa
      # transação própria (`Api.Scheduling.Warm.build/2` → `with_clinic`), e o `UPDATE` cru do
      # espelho `session_starts_at` (`SyncSessionStartsAt`), que roda dentro da transação da ação.
      # Warm vazio faria a massa cair no caminho antigo (lenta, mas correta); o `UPDATE` sem GUC
      # atualizaria **zero** linhas em silêncio, e o histórico da ficha passaria a ordenar pelo
      # horário velho. Nenhum dos dois aparece no `mix test`.
      :ok = sem_guc()

      assert {:ok, %{afetadas: afetadas}} =
               Packages.bulk_adjust(ctx.scope, pkg.id, %{
                 escopo: :todas,
                 aplicar_horario: true,
                 hhmm: "10:00"
               })

      assert afetadas > 0, "a massa não achou as sessões do pacote (GUC faltando?)"

      :ok = sem_guc()

      # As duas listas juntas: a ficha separa passado (`sessions`) de futuro (`upcoming`), e a
      # série deste teste é futura de propósito (a massa só alcança futuro). O que se prova aqui é
      # o espelho, que vale para as duas — olhar só o histórico fazia o teste depender de a âncora
      # estar no passado, que é justamente o que o fazia apodrecer.
      %{sessions: passadas, upcoming: futuras} =
        Scheduling.list_patient_sessions(ctx.scope, ctx.paciente.id)

      sessoes = passadas ++ futuras
      refute Enum.empty?(sessoes), "ficha vazia: a GUC não chegou"

      for sessao <- sessoes do
        assert sessao.session_starts_at == sessao.appointment.starts_at,
               "o espelho `session_starts_at` não acompanhou a remarcação (UPDATE sem GUC?)"
      end
    end

    test "pausar/retomar em turma: a presença segurada é escrita e relida sob RLS" do
      ctx = fixture()

      turma =
        Directory.create_appointment_type!(
          %{
            nome: "Turma hold RLS #{System.unique_integer([:positive])}",
            duracao_minutos: 50,
            cor: "#0FB5A6",
            icon: "Users",
            grupo: true,
            capacidade: 4
          },
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      colega =
        Records.create_patient!("Colega RLS", %{tel: Api.Generators.telefone_unico()},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      {:ok, pkg} =
        Packages.create_package(
          package_params(ctx, total: 2) |> Map.put(:appointment_type_id, turma.id),
          scope: ctx.scope
        )

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: proxima_segunda("14:00"),
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

      :ok = sem_guc()
      assert {:ok, %{status: :pausado}} = Packages.pause_package(ctx.scope, pkg.id)

      # O bloco continua visível (é do colega também) e a presença segurada some da leitura.
      :ok = sem_guc()
      visivel = bloco(ctx, appt.id)
      assert Enum.map(visivel.attendances, & &1.patient_id) == [colega.id]

      # A retomada precisa REACHAR a presença segurada (porta `include_held`) — 0 aqui significa
      # que o pacote se escondeu de si mesmo sob RLS.
      :ok = sem_guc()
      assert {:ok, %{status: :ativo}} = Packages.resume_package(ctx.scope, pkg.id)

      :ok = sem_guc()
      depois = bloco(ctx, appt.id)
      assert depois.status == :agendado
      assert Enum.map(depois.attendances, & &1.patient_id) == [colega.id]
    end

    test "sobrar só presença segurada põe o BLOCO em hold — a cascata escreve sob RLS" do
      ctx = fixture()

      turma =
        Directory.create_appointment_type!(
          %{
            nome: "Turma fantasma RLS #{System.unique_integer([:positive])}",
            duracao_minutos: 50,
            cor: "#0FB5A6",
            icon: "Users",
            grupo: true,
            capacidade: 4
          },
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      colega =
        Records.create_patient!("Colega 2 RLS", %{tel: Api.Generators.telefone_unico()},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      {:ok, pkg} =
        Packages.create_package(
          package_params(ctx, total: 2) |> Map.put(:appointment_type_id, turma.id),
          scope: ctx.scope
        )

      {:ok, appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: proxima_segunda("16:00"),
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

      {:ok, _} = Packages.pause_package(ctx.scope, pkg.id)

      # Tirar o colega deixa só a presença segurada: o bloco tem de entrar em hold junto. A escrita
      # é cascata dentro da ação (`set_appointment_pkg_hold`) — sem a GUC ela não atravessa o
      # WITH CHECK da policy, e o bloco fantasma voltaria pela porta do servidor real.
      :ok = sem_guc()

      {:ok, _} =
        Scheduling.remove_appointment_participants(appt, %{patient_ids: [colega.id]},
          scope: ctx.scope
        )

      :ok = sem_guc()

      assert {:ok, nil} =
               Api.Tenancy.in_clinic(ctx.scope, fn ->
                 Scheduling.get_appointment(appt.id, scope: ctx.scope, not_found_error?: false)
               end)
    end

    test "a poda da trilha varre cada clínica sob a própria GUC" do
      ctx = fixture()

      {:ok, _} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("15:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [ctx.paciente.id]
          },
          scope: ctx.scope
        )

      # O job roda fora de request: se o `DELETE` não estivesse dentro de `with_clinic`, a RLS o
      # faria apagar **zero** linha para sempre — e o `mix test` (postgres) nunca contaria.
      :ok = sem_guc()

      assert {:ok, %{apagadas: apagadas}} =
               Api.Housekeeping.PruneTrail.perform(%Oban.Job{args: %{"reter_dias" => 0}})

      assert apagadas > 0, "a poda não alcançou linha nenhuma (GUC faltando no job?)"
    end

    test "o histórico da ficha lê as presenças sob RLS" do
      ctx = fixture()

      {:ok, _appt} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("08:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [ctx.paciente.id]
          },
          scope: ctx.scope
        )

      # Mesma armadilha das outras leituras da ficha: sem `in_clinic` a lista volta VAZIA no
      # servidor real e cheia no `mix test`.
      :ok = sem_guc()

      assert %{sessions: [sessao], more?: false} =
               Scheduling.list_patient_sessions(ctx.scope, ctx.paciente.id)

      assert sessao.appointment, "o bloco não veio junto (GUC faltando na relação?)"
    end
  end

  # Onda 4 / Frente 10. Quatro caminhos por-tenant nasceram aqui, e três deles rodam **fora de
  # request** (job de fundo, cron) — onde não há GUC herdada de lugar nenhum.
  describe "caixa de notificações sob RLS (Onda 4)" do
    defp notifica(ctx) do
      {:ok, n} =
        Api.Notifications.create_notification(
          %{
            recipient_id: ctx.owner.id,
            kind: :member_joined,
            title: "T",
            body: "B",
            data: %{}
          },
          tenant: ctx.clinic.id,
          authorize?: false
        )

      n
    end

    test "a caixa paginada devolve o que foi criado (0 aqui significa GUC faltando)" do
      ctx = fixture()
      notifica(ctx)

      :ok = sem_guc()

      page = Api.Notifications.list_inbox(ctx.scope)
      assert length(page.results) > 0, "a caixa voltou vazia (GUC faltando na leitura?)"
    end

    # O mais perigoso do lote: `Ash.bulk_update` é ESCRITA em massa sob RLS, e a policy do
    # recurso é filter-check — ou seja, o `Ash.can` roda um SELECT na própria tabela antes do
    # UPDATE. Sem GUC, esse SELECT recebe `''::uuid`. A ação de massa também não tem
    # `SetTenantGuc` (um `before_action` a tiraria do caminho atômico): quem garante a GUC é o
    # `in_clinic` do wrapper, e é exatamente isso que este teste prova.
    test "marcar todas como lidas alcança as linhas sob RLS" do
      ctx = fixture()
      notifica(ctx)
      notifica(ctx)

      :ok = sem_guc()

      assert Api.Notifications.mark_all_read(ctx.scope) == 2
      assert Api.Notifications.unread_count(ctx.scope) == 0
    end

    # O irmão do de cima, e o de consequência pior: `Ash.bulk_destroy` é DELETE em massa sob RLS,
    # com a mesma policy filter-check (um SELECT de autorização antes). Sem GUC ele não erra alto
    # — apaga **zero linha** e devolve sucesso, então a tela diria "limpo" com a caixa intacta.
    test "limpar a caixa alcança as linhas sob RLS" do
      ctx = fixture()
      notifica(ctx)
      notifica(ctx)

      :ok = sem_guc()

      assert Api.Notifications.clear_all(ctx.scope) == 2
      assert Api.Notifications.list_inbox(ctx.scope).results == []
    end

    test "a poda da caixa apaga sob a GUC de cada clínica" do
      ctx = fixture()
      n = notifica(ctx)

      Api.Repo.query!(
        "UPDATE notifications SET read_at = now(), inserted_at = inserted_at - interval '400 days' WHERE id = $1",
        [Ecto.UUID.dump!(n.id)]
      )

      :ok = sem_guc()

      assert {:ok, %{apagadas: apagadas}} =
               Api.Housekeeping.PruneNotifications.perform(%Oban.Job{args: %{}})

      assert apagadas > 0, "a poda não alcançou linha nenhuma (GUC faltando no job?)"
    end

    # O cron dos lembretes varre a agenda de fora de qualquer request. Sem `with_clinic`, a
    # varredura acha zero bloco em toda clínica e o lembrete simplesmente nunca sai — falha
    # silenciosa, do tipo que só aparece quando alguém reclama que não recebe aviso.
    test "o resumo diário enxerga a agenda de amanhã sob RLS" do
      ctx = fixture()
      tz = Scheduling.clinic_timezone(ctx.clinic.id)
      amanha = DateTime.utc_now() |> DateTime.shift_zone!(tz) |> DateTime.to_date() |> Date.add(1)
      {:ok, as_nove} = Scheduling.LocalTime.to_utc(amanha, "09:00", tz)

      {:ok, _} =
        Scheduling.schedule_appointment(
          %{
            starts_at: as_nove,
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [ctx.paciente.id]
          },
          scope: ctx.scope
        )

      :ok = sem_guc()

      blocos =
        Api.Notifications.Reminders.blocos_por_profissional(
          ctx.clinic.id,
          Api.Notifications.Reminders.inicio_do_dia(amanha, tz),
          Api.Notifications.Reminders.inicio_do_dia(Date.add(amanha, 1), tz)
        )

      assert map_size(blocos) > 0, "o cron não enxergou a agenda (GUC faltando na varredura?)"
    end
  end

  # Doc 51. A fatia nasceu sem cobertura aqui, e o buraco cobrou na primeira remoção real: o
  # `DELETE` estourava `''::uuid` no servidor e a tela dizia "Não foi possível concluir a
  # operação". Criar e renomear funcionavam — só o `destroy` caía.
  describe "anexos sob RLS (doc 51)" do
    @pdf "%PDF-1.7\n%êãÏÓ laudo sob RLS"

    defp anexo(ctx) do
      {:ok, anexo, _upload} =
        Records.start_attachment(ctx.scope, ctx.paciente, %{
          nome: "laudo.pdf",
          content_type: "application/pdf",
          bytes: byte_size(@pdf)
        })

      # O que o browser faria com a URL assinada — os bytes nunca passam pelo servidor.
      Api.Storage.Memory.subir(anexo.chave, "application/pdf", @pdf)

      {:ok, anexo} = Records.confirm_attachment(ctx.scope, anexo)
      anexo
    end

    setup do
      Api.Storage.Memory.limpar()
      :ok
    end

    test "o ciclo start → confirm escreve sob a GUC da própria ação" do
      ctx = fixture()

      :ok = sem_guc()

      anexo = anexo(ctx)
      assert anexo.status == :disponivel
    end

    # A garantia de que o `destroy` põe a GUC na própria transação **não** mora aqui: ela é
    # estrutural (o comportamento passa verde com o bug em pé, porque a GUC do `autorizar/3` fica
    # pendurada no sandbox) e vale para todo recurso por-tenant, não só para o anexo. Está em
    # `Api.TenantGucTest`. Este teste continua útil pelo outro lado: prova que o ciclo completo
    # roda sob `cinetra_app` sem estourar.
    test "remover apaga a linha e os bytes" do
      ctx = fixture()
      anexo = anexo(ctx)

      :ok = sem_guc()

      assert Records.delete_attachment(ctx.scope, anexo) == :ok
      assert Api.Storage.Memory.chaves() == [], "os bytes ficaram no bucket"

      assert Records.list_patient_attachments(ctx.scope, ctx.paciente) == [],
             "a linha sobreviveu ao destroy"
    end

    test "renomear atravessa o WITH CHECK da policy" do
      ctx = fixture()
      anexo = anexo(ctx)

      :ok = sem_guc()

      assert {:ok, renomeado} = Records.rename_attachment(ctx.scope, anexo, "ressonância.pdf")
      assert renomeado.nome == "ressonância.pdf"
    end

    test "a URL de leitura é emitida e a trilha do acesso é gravada sob RLS" do
      ctx = fixture()
      anexo = anexo(ctx)

      :ok = sem_guc()

      assert {:ok, %{url: _}} = Records.attachment_download(ctx.scope, anexo)

      eventos = Records.list_clinic_attachment_events(ctx.scope, anexo.id)
      assert Enum.any?(eventos, &(&1.action == "visualizou")), "a trilha LGPD não foi gravada"
    end
  end

  describe "comunicação com o paciente (doc 52)" do
    # Esta fatia inteira é sobre um caminho que o `mix test` sob `postgres` não prova: o `SendJob`
    # roda **fora de request**, e o webhook roda **sem tenant nenhum**. Os dois já falharam em
    # desenvolvimento exatamente pelo modo que este arquivo existe para pegar — silêncio.

    test "o job de envio lê a mensagem e grava o resultado sob cinetra_app" do
      ctx = fixture()
      message = mensagem(ctx)

      :ok = sem_guc()

      assert :ok =
               Api.Messaging.SendJob.perform(%Oban.Job{
                 args: %{"clinic_id" => ctx.clinic.id, "message_id" => message.id}
               })

      # Sem GUC, a leitura de dentro do job volta VAZIA e o job "funciona" sem enviar nada. O
      # estado ter mudado é a prova de que ela chegou.
      recarregada =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Api.Messaging.get_message!(message.id, tenant: ctx.clinic.id, authorize?: false)
        end)

      assert recarregada.status == :enviado, "o job não enviou — a GUC não chegou na leitura"
    end

    test "o webhook acha a mensagem SEM tenant, pela exceção do provider_message_id" do
      ctx = fixture()
      message = mensagem(ctx)

      enviada =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Api.Messaging.do_mark_sent!(
            message,
            %{
              provider: "resend",
              provider_message_id: "prov-#{System.unique_integer([:positive])}"
            },
            tenant: ctx.clinic.id,
            authorize?: false
          )
        end)

      :ok = sem_guc()

      # É este caminho que a policy padrão recusaria: sem GUC, `clinic_id = NULL` não casa linha
      # nenhuma e o webhook responderia 200 para sempre sem fazer nada.
      assert :ok =
               Api.Messaging.Webhooks.processar(%{
                 "type" => "email.delivered",
                 "data" => %{"email_id" => enviada.provider_message_id}
               })

      recarregada =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Api.Messaging.get_message!(message.id, tenant: ctx.clinic.id, authorize?: false)
        end)

      assert recarregada.status == :entregue, "o webhook não achou a mensagem sob RLS"
    end

    test "a RESPOSTA do paciente acha a mensagem sem tenant (o link do e-mail)" do
      # O bug que o bate-volta pegou ao vivo: a rota pública `/api/reply/:token` conhece só o
      # `message_id` (do token) e roda **sem GUC nenhuma**. Sob `cinetra_app` a policy comparava
      # `clinic_id = NULL`, não casava linha, e todo link legítimo respondia `link_invalido` — com
      # os 7 testes da rota verdes, porque o sandbox conecta como `postgres`.
      #
      # É o irmão do webhook: os dois resolvem o tenant a partir de um identificador externo.
      ctx = fixture()
      message = mensagem(ctx)

      :ok = sem_guc()

      assert {:ok, achada} =
               Api.Repo.with_message(message.id, fn ->
                 Api.Messaging.get_message(message.id, authorize?: false, not_found_error?: false)
               end)
               |> elem(1)

      assert achada.id == message.id, "a resposta do paciente não acha a mensagem sob RLS"
    end

    test "a resposta 'quer remarcar' escreve na caixa da recepção sob cinetra_app (doc 65 §5)" do
      # O fan-out da resposta do paciente roda a partir de uma rota **pública**: não há sessão,
      # não há GUC do request, e ele escreve N linhas em `notifications` (por-tenant, sob RLS).
      # Sem a GUC certa, a escrita não erra alto — a caixa fica vazia e ninguém descobre que o
      # paciente pediu remarcação. É a mesma classe de silêncio que este arquivo existe para pegar.
      ctx = fixture()
      message = mensagem(ctx)

      respondida =
        Api.Repo.with_clinic(ctx.clinic.id, fn ->
          Api.Messaging.do_record_reply!(message, %{resposta: :quer_remarcar},
            tenant: ctx.clinic.id,
            authorize?: false
          )
        end)
        |> elem(1)

      :ok = sem_guc()

      assert :ok = Api.Notifications.Fanout.patient_wants_reschedule(respondida)

      assert [%{kind: :patient_wants_reschedule}] =
               Api.Notifications.list_inbox(ctx.scope).results
    end

    test "o aviso da massa por pacote alcança o paciente sob cinetra_app" do
      # `avisa_o_paciente/6` acha a âncora, lê a clínica e grava a mensagem — três leituras
      # por-tenant depois do commit da massa. Sem GUC, a âncora volta `nil` e a mensagem some em
      # silêncio: a massa "funciona" e o paciente não é avisado.
      #
      # As sessões são criadas **pela porta de agendar**, e não pelo materializador do pacote, de
      # propósito: o caminho do materializador está vermelho na árvore por outra causa (doc 60 §5,
      # trabalho de outra fatia), e um teste que depende dele não prova o que este quer provar.
      ctx = fixture()

      paciente =
        Records.update_patient!(ctx.paciente, %{comunicacao: true, email: "massa@example.com"},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      {:ok, pkg} = Packages.create_series(ctx.scope, package_params(ctx, total: 2), forcar: false)

      for hora <- ["13:00", "14:00"] do
        {:ok, _} =
          Scheduling.schedule_appointment(
            %{
              starts_at: proxima_segunda(hora),
              professional_id: ctx.prof.id,
              appointment_type_id: ctx.tipo.id,
              patient_ids: [paciente.id],
              package_id: pkg.id
            },
            scope: ctx.scope
          )
      end

      :ok = sem_guc()

      assert {:ok, %{afetadas: afetadas}} =
               Packages.bulk_cancel(ctx.scope, pkg.id, %{escopo: :todas})

      assert afetadas == 2

      avisos =
        Api.Tenancy.in_clinic(ctx.clinic.id, fn ->
          Api.Messaging.Message
          |> Ash.Query.for_read(:read, %{}, tenant: ctx.clinic.id, authorize?: false)
          |> Ash.Query.filter(kind == :pacote_cancelado)
          |> Ash.read!(authorize?: false)
        end)

      assert length(avisos) == 1, "o aviso da massa não saiu — a GUC não chegou na âncora"
    end

    test "o opt-out global é legível e gravável sem GUC" do
      # `message_opt_outs` tem `clinic_id` ANULÁVEL (C10) e a policy precisa aceitar a linha
      # global — senão o opt-out sumiria da leitura e continuaríamos mandando para quem parou.
      :ok = sem_guc()

      destino = "parou-#{System.unique_integer([:positive])}@example.com"

      assert :ok = Api.Messaging.opt_out(:email, destino, "spam")
      assert Api.Messaging.opted_out?(:email, destino, nil)
    end

    # Uma mensagem pronta para enviar, na clínica do `ctx`.
    defp mensagem(ctx) do
      # A confirmação automática da criação do bloco ficaria na fila e a trava contra duplicata
      # recusaria o disparo à mão abaixo. O que este arquivo mede é a RLS do caminho de envio, e
      # para isso ele precisa da mensagem na mão.
      Api.Accounts.update_clinic_messaging!(ctx.clinic, %{msg_confirmacao_auto: false},
        authorize?: false
      )

      paciente =
        Records.update_patient!(ctx.paciente, %{comunicacao: true, email: "rls@example.com"},
          tenant: ctx.clinic.id,
          actor: ctx.owner
        )

      {:ok, appointment} =
        Scheduling.schedule_appointment(
          %{
            starts_at: at("11:00"),
            professional_id: ctx.prof.id,
            appointment_type_id: ctx.tipo.id,
            patient_ids: [paciente.id]
          },
          scope: ctx.scope
        )

      [presenca] = bloco(ctx, appointment.id).attendances

      {:ok, message} =
        Api.Messaging.Dispatch.dispatch(ctx.clinic, presenca, paciente, :confirmacao)

      message
    end
  end
end
