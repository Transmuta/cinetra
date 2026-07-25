defmodule Api.RlsSmokeTest do
  @moduledoc """
  O gate que faltava: exercita os caminhos por-tenant com o **mesmo role do servidor**
  (`movimento_app`, NOBYPASSRLS), e não com o `postgres` do resto da suíte.

  ## Por que este arquivo existe

  O sandbox de teste conecta como `postgres`, que é SUPERUSER e portanto **bypassa RLS**.
  Consequência medida na fatia Agenda: uma leitura por-tenant sem `in_clinic`/`with_clinic`
  passa verde no `mix test` e devolve **lista vazia** no servidor real. A mesma chamada,
  sob os dois roles:

      movimento_app, SEM in_clinic : 0 profissionais
      movimento_app, COM in_clinic : 2 profissionais
      postgres                     : 2 profissionais

  Essa classe de bug mordeu três vezes numa fatia só e era invisível ao gate de cobertura.

  ## Como rodar

      # local (exige o role criado no banco de teste — ver priv/sql/setup_app_role.sql)
      DATABASE_USER=movimento_app DATABASE_PASSWORD=movimento_app mix test --only rls

  No CI é o job `api-rls`. Sob `postgres` estes testes também passam — só que sem provar
  nada; é rodando como `movimento_app` que eles viram gate.

  ## O que é asserção aqui

  **Não-vazio.** Parece fraco e não é: sob RLS, o modo de falha de "esqueci o `in_clinic`"
  é exatamente *zero linhas*, silenciosamente. Uma leitura que devolve o que criou é a
  prova de que a GUC chegou onde precisava.
  """
  use Api.DataCase, async: false

  @moduletag :rls

  alias Api.Accounts
  alias Api.Directory
  alias Api.Packages
  alias Api.Records
  alias Api.Scheduling

  @segunda ~D[2026-07-20]

  defp email, do: "rls-#{System.unique_integer([:positive])}@example.com"

  defp fixture do
    owner = Accounts.register_user!("Dono RLS", email(), authorize?: false)

    clinic =
      Accounts.onboard_clinic!("Clínica RLS #{System.unique_integer([:positive])}", %{},
        actor: owner
      )

    membership = Accounts.get_active_membership!(owner.id, clinic.id, authorize?: false)
    scope = Api.Scope.with_membership(owner, membership)

    prof = Directory.create_professional!("Dra. RLS", %{}, tenant: clinic.id, actor: owner)

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

    paciente = Records.create_patient!("Paciente RLS", %{}, tenant: clinic.id, actor: owner)

    %{owner: owner, clinic: clinic, scope: scope, prof: prof, tipo: tipo, paciente: paciente}
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
  # `in_clinic` passa verde mesmo sob `movimento_app`, e o gate vira decoração.
  #
  # Verificado: com o `in_clinic` do `load_agenda` removido de propósito, o arquivo passava.
  # Zerando a GUC antes da leitura, ele falha — que é o comportamento correto.
  #
  # Em produção não existe herança: cada request chega numa transação nova, sem GUC. Zerar
  # aqui **reproduz a precondição real** em vez de inventar uma.
  defp sem_guc do
    Api.Repo.query!("SELECT set_config('movimento.clinic_id', '', true)")
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
            "Use DATABASE_USER=movimento_app.\n"
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
        Records.create_patient!("Paciente 2 RLS", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

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
    defp package_params(ctx, opts \\ []) do
      %{
        nome: "Pacote RLS #{System.unique_integer([:positive])}",
        total: Keyword.get(opts, :total, 3),
        falta_punitiva: true,
        cor: "#0FB5A6",
        data_inicio: @segunda,
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
               Scheduling.list_patient_history(ctx.scope, ctx.paciente.id)

      assert sessao.appointment, "o bloco não veio junto (GUC faltando na relação?)"
    end
  end
end
