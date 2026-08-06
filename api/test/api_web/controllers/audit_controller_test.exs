defmodule ApiWeb.AuditControllerTest do
  @moduledoc """
  `GET /api/audit` (doc 25 §11.4) — a fronteira HTTP da tela de auditoria. Integração real:
  sessão + `LoadScope`, o RBAC **owner·admin** (403 para recepção/profissional, não lista
  vazia) e o formato do JSON que o BFF consome.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records
  alias Api.Scheduling

  # Uma clínica com um agendamento já cancelado — três versões na trilha (schedule/reschedule/
  # cancel), do owner. Devolve o escopo e o contexto para as asserções.
  defp fixture do
    owner = sign_in!(email_unico("audit-http"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    prof =
      Directory.create_professional!("Dra. Bea", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        actor: owner
      )

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

    paciente =
      Records.create_patient!("Caio", %{tel: Api.Generators.telefone_unico()},
        tenant: clinic.id,
        actor: owner
      )

    scope = scope_for(owner, clinic)

    {:ok, appt} =
      Scheduling.schedule_appointment(
        %{
          starts_at: ~U[2026-07-20 11:00:00Z],
          professional_id: prof.id,
          appointment_type_id: tipo.id,
          patient_ids: [paciente.id]
        },
        scope: scope
      )

    {:ok, _} =
      Scheduling.transition_appointment(scope, appt.id, :reschedule, %{
        starts_at: ~U[2026-07-20 12:00:00Z]
      })

    {:ok, _} = Scheduling.transition_appointment(scope, appt.id, :cancel, %{cancel_reason: "x"})

    # Um segundo bloco, com uma falta. É ele que rende linha de PRESENÇA: as escritas de presença
    # em cascata (a criação do bloco, o cancelamento) contam pela linha do bloco — um fato, uma
    # linha. Quem decide sobre a presença é a falta, e essa tem linha própria.
    {:ok, outro} =
      Scheduling.schedule_appointment(
        %{
          starts_at: ~U[2026-07-20 17:00:00Z],
          professional_id: prof.id,
          appointment_type_id: tipo.id,
          patient_ids: [paciente.id]
        },
        scope: scope
      )

    {:ok, _} =
      Scheduling.transition_participant(scope, outro.id, paciente.id, :no_show, %{
        motivo: "não avisou"
      })

    %{
      owner: owner,
      clinic: clinic,
      prof: prof,
      paciente: paciente,
      appt: appt,
      com_falta: outro
    }
  end

  defp scope_for(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  describe "GET /api/audit" do
    test "owner recebe 200 com o feed e a meta de página", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit")

      body = json_response(conn, 200)
      assert %{"entries" => entries, "page" => page} = body

      # Sem `?resource=`, o feed é da CLÍNICA INTEIRA (doc 63, D-Aud3) — não mais só a agenda.
      # É a pergunta que o modelo anterior não respondia; por isso a fixture (que mexe em
      # clínica, profissional, paciente, tipo e agenda) rende mais que as 3 versões do bloco.
      recursos = entries |> Enum.map(& &1["resource"]) |> Enum.uniq()
      assert "appointment" in recursos
      assert "attendance" in recursos

      # **Sem `total` no corpo** (D-Aud1): medido em 265× o custo da própria página, ~99% do
      # tempo de banco da request. O `more` é exato e é o que habilita a paginação.
      # `total` existe SEMPRE no wire e vem `nil` quando a leitura não contou (doc 96, H-8): a
      # ausência da chave era o que obrigava o cliente a saber, endpoint a endpoint, se ela
      # apareceria. A decisão de não contar (`count: false`, caríssimo na trilha) continua a
      # mesma — o que mudou é como ela é dita.
      assert page["total"] == nil
      assert page["more"] == false

      # Quem · quando · ação · registro · diff, na entrada do cancelamento.
      cancel = Enum.find(entries, &(&1["action"] == "cancel"))
      assert cancel["resource"] == "appointment"
      assert cancel["actor"]["nome"] == ctx.owner.nome
      assert cancel["professional"]["nome"] == "Dra. Bea"

      # …e DE QUEM era a sessão: o bloco não tem paciente (quem tem são as presenças), então sem
      # `participants` a linha de agenda saía sem o dado que a identifica.
      assert Enum.map(cancel["participants"], & &1["nome"]) == ["Caio"]
      assert is_binary(cancel["at"])
      assert Enum.any?(cancel["diff"], &(&1["field"] == "status" and &1["to"] == "cancelado"))
    end

    test "admin também lê", %{conn: conn} do
      ctx = fixture()
      admin = sessao_de_membro!(ctx.owner, ctx.clinic, :admin)

      conn = conn |> authed(admin) |> get("/api/audit")
      assert %{"entries" => [_ | _]} = json_response(conn, 200)
    end

    # Bate-volta (causa C3): o 403 é registrado pelo `TenantScope.forbidden/1`, que é o ponto por
    # onde TODO 403 do projeto passa. Este teste atravessa o pipeline do Router de verdade — é a
    # única forma de provar a fiação, porque o domínio sozinho não passa por ali.
    #
    # A dedup **não existia**: `record_id` é nulo em `:seguranca` e a guarda curto-circuitava,
    # então cada resposta negada virava uma linha (medido: 100 requests → 100 linhas). Um cliente
    # em laço afogava o sinal que a trilha existe para dar.
    test "403 repetido não vira uma linha por request na trilha" do
      ctx = fixture()
      recepcao = sessao_de_membro!(ctx.owner, ctx.clinic, :recepcao)

      for _ <- 1..5 do
        assert build_conn() |> authed(recepcao) |> get("/api/audit") |> json_response(403)
      end

      scope = scope_for(ctx.owner, ctx.clinic)
      %{entries: entries} = Api.Audit.list_events(scope, resource: :seguranca)

      assert [evento] = entries
      assert evento.label == "/api/audit"
    end

    test "recepção recebe 403 (não lista vazia)", %{conn: conn} do
      ctx = fixture()
      recepcao = sessao_de_membro!(ctx.owner, ctx.clinic, :recepcao)

      conn = conn |> authed(recepcao) |> get("/api/audit")
      assert json_response(conn, 403)
    end

    test "profissional recebe 403", %{conn: conn} do
      ctx = fixture()
      prof_user = sessao_de_membro!(ctx.owner, ctx.clinic, :profissional, ctx.prof.id)

      conn = conn |> authed(prof_user) |> get("/api/audit")
      assert json_response(conn, 403)
    end

    test "sem sessão é 401", %{conn: conn} do
      conn = get(conn, "/api/audit")
      assert json_response(conn, 401)
    end

    test "filtra por ação", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?action=cancel")

      assert %{"entries" => [entry]} = json_response(conn, 200)
      assert entry["action"] == "cancel"
    end

    test "resource=attendance devolve as versões de participante com o paciente", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?resource=attendance")

      body = json_response(conn, 200)
      assert Enum.all?(body["entries"], &(&1["resource"] == "attendance"))
      assert [entry | _] = body["entries"]
      assert entry["patient"]["nome"] == "Caio"
    end

    # A versão de participante não carrega horário nem profissional — são do agendamento. Sem
    # este enriquecimento a linha da tela não diz **de qual sessão** se fala, e não há como
    # oferecer "ver na agenda" (a agenda é navegada por dia).
    test "resource=attendance traz o contexto do agendamento (quando e com quem)", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?resource=attendance")

      assert [entry | _] = json_response(conn, 200)["entries"]

      # O contexto do participante viaja em `meta` (doc 63): `appointment_id` para o link "ver na
      # agenda" e `session_starts_at` — o espelho denormalizado do horário do bloco (doc 43) —
      # para a linha dizer DE QUAL sessão se fala. O modelo anterior fazia duas leituras a mais
      # por página para descobrir os dois; agora eles são gravados junto com o evento.
      assert entry["meta"]["appointment_id"] == ctx.com_falta.id
      assert is_binary(entry["meta"]["session_starts_at"])
      assert entry["patient"]["nome"] == "Caio"

      # O "com quem" do título deste teste só passou a ser verdade agora: o `professional_id`
      # mora no BLOCO, não na presença, então a linha do participante vinha sem ele — e o
      # enriquecimento o resolve pelo bloco, em lote.
      assert entry["professional"]["nome"] == "Dra. Bea"
    end

    # A whitelist de `parse_action` decide o que é filtrável; nome fora dela vira filtro **nulo**
    # (o feed inteiro volta, e quem filtrou não percebe). Ela nasceu incompleta: `exclude`,
    # `apply_participant_rollup`, `set_pkg_hold` e as ações de presença estavam de fora, e todas
    # existem no banco.
    # A whitelist de `parse_action` é mantida à MÃO e falha em silêncio: nome fora dela vira
    # filtro `nil` — o feed inteiro volta com 200 e quem filtrou não percebe. O bate-volta provou
    # que ela estava desprotegida: reduzi-la de 20 nomes para dois deixou os 1177 testes verdes.
    #
    # Este teste tira a verdade do Ash, não de uma lista digitada de novo: TODA ação de escrita
    # dos dois recursos precisa filtrar de fato. Ação nova amanhã cai aqui sem ninguém lembrar.
    # É `⊇`, não igualdade: a whitelist carrega também nomes APOSENTADOS (`mark_completed`,
    # `set_package`), que sumiram do recurso mas continuam gravados na trilha.
    test "toda ação de escrita dos recursos é filtrável de fato", %{conn: conn} do
      ctx = fixture()
      conn = authed(conn, ctx.owner)

      acoes =
        [Api.Scheduling.Appointment, Api.Scheduling.Attendance]
        |> Enum.flat_map(fn res ->
          res
          |> Ash.Resource.Info.actions()
          |> Enum.filter(&(&1.type in [:create, :update, :destroy]))
          |> Enum.map(&to_string(&1.name))
        end)
        |> Enum.uniq()

      for acao <- acoes, recurso <- ~w(appointment attendance) do
        entries =
          conn
          |> get("/api/audit?resource=#{recurso}&action=#{acao}")
          |> json_response(200)
          |> Map.fetch!("entries")

        # Vazio é resposta legítima (a fixture não tem essa ação); o que não pode é voltar
        # entrada de OUTRA ação — sinal de que o filtro foi descartado.
        assert Enum.all?(entries, &(&1["action"] == acao)),
               "filtro action=#{acao} (#{recurso}) foi ignorado: voltou " <>
                 inspect(Enum.map(entries, & &1["action"]) |> Enum.uniq())
      end
    end

    # A whitelist de `parse_action` **deixou de existir** (doc 63). Ela era mantida à mão e
    # falhava em silêncio: nome fora dela virava filtro `nil` — o feed inteiro voltava com 200 e
    # quem filtrou não percebia. O bate-volta provou que ela estava desprotegida (reduzi-la de 20
    # nomes para dois deixou os 1177 testes verdes), e nasceu já sem dez nomes que o banco tinha.
    #
    # Em `audit_events` a coluna `action` é TEXTO: o filtro é comparação de string, e nome
    # desconhecido devolve **vazio** — a resposta honesta — em vez do feed inteiro. É o que este
    # teste trava, e é uma garantia mais forte que a lista era capaz de dar.
    test "ação desconhecida devolve VAZIO, não o feed inteiro", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?action=acao_que_nunca_existiu")

      assert %{"entries" => []} = json_response(conn, 200)
    end

    # A lista fechada que SOBROU é a de recursos — e essa é o enum do próprio recurso, não uma
    # lista digitada. Valor fora dela é 422, e não filtro nulo: um `?resource=pacinete` que
    # devolvesse o feed inteiro repetiria exatamente o erro da whitelist de ações.
    test "resource desconhecido é 422 (não o feed inteiro sem filtro)", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?resource=pacinete")

      assert json_response(conn, 422)
    end

    test "resource aceita vários, separados por vírgula", %{conn: conn} do
      ctx = fixture()

      conn =
        conn |> authed(ctx.owner) |> get("/api/audit?resource=appointment,attendance")

      assert %{"entries" => entries} = json_response(conn, 200)
      assert entries != []
      assert Enum.all?(entries, &(&1["resource"] in ["appointment", "attendance"]))
    end

    test "filtra por uma ação que não estava na whitelist original", %{conn: conn} do
      ctx = fixture()
      scope = scope_for(ctx.owner, ctx.clinic)
      {:ok, _} = Scheduling.transition_appointment(scope, ctx.appt.id, :exclude, %{})

      conn = conn |> authed(ctx.owner) |> get("/api/audit?action=exclude")

      assert %{"entries" => [entry]} = json_response(conn, 200)
      assert entry["action"] == "exclude"
    end

    test "pagina por limit/offset", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?limit=2&offset=0")

      body = json_response(conn, 200)
      assert length(body["entries"]) == 2
      assert body["page"]["more"] == true
    end

    test "janela from/to malformada é 422", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?from=nao-e-data")

      assert json_response(conn, 422)
    end

    # Bate-volta (segurança, MÉDIO): um `record_id`/`user_id` não-uuid chegava cru no filtro de
    # coluna UUID e estourava `Ecto.Query.CastError` → HTTP 500. A fronteira valida como já faz
    # com `from`/`to` (422) e `limit`/`offset` (default) — nunca deixa o cast subir.
    test "record_id malformado (não-uuid) é 422, não 500", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?record_id=nao-e-uuid")
      assert json_response(conn, 422)
    end

    test "user_id malformado (não-uuid) é 422, não 500", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?user_id=xxx")
      assert json_response(conn, 422)
    end

    # Bate-volta (verificação): um offset gigante é absorvido pelo clamp (100k) — não chega cru
    # no Postgrex a ponto de estourar o int64 e virar 500. Mesma classe do 500 de uuid.
    test "offset absurdo é clampado, não 500", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?offset=999999999999")
      assert %{"entries" => []} = json_response(conn, 200)
    end

    # `to` anterior a `from` é 422 (a mesma regra de janela da agenda, via parse_window).
    test "janela invertida (to < from) é 422", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/audit?from=2026-07-20&to=2026-07-19")
      assert json_response(conn, 422)
    end

    test "janela válida (from/to) recorta por QUANDO a mudança foi gravada", %{conn: conn} do
      ctx = fixture()

      # A janela é sobre `version_inserted_at` (quando a trilha registrou), não sobre a data do
      # agendamento — então gira em torno de "hoje", que é quando as três versões nasceram.
      hoje = Date.utc_today()
      ontem = Date.add(hoje, -1)
      amanha = Date.add(hoje, 1)

      conn = conn |> authed(ctx.owner) |> get("/api/audit?from=#{ontem}&to=#{amanha}")
      assert %{"entries" => [_ | _]} = json_response(conn, 200)

      # Uma janela no passado distante não vê nada — a conversão local→UTC segurou a borda.
      conn2 = build_conn() |> authed(ctx.owner) |> get("/api/audit?from=2020-01-01&to=2020-01-02")
      assert %{"entries" => []} = json_response(conn2, 200)
    end

    test "filtra por registro (record_id) e por autor (user_id)", %{conn: conn} do
      ctx = fixture()

      conn = conn |> authed(ctx.owner) |> get("/api/audit?record_id=#{ctx.appt.id}")
      body = json_response(conn, 200)

      por_recurso = Enum.frequencies_by(body["entries"], & &1["resource"])
      assert por_recurso["appointment"] == 3

      assert Enum.all?(body["entries"], fn e ->
               e["record_id"] == ctx.appt.id or e["meta"]["appointment_id"] == ctx.appt.id
             end)

      # O recorte de um bloco traz o bloco **e os participantes dele** — quem faltou e por quê
      # mora na presença, que tem `record_id` próprio. Casar só o `record_id` deixava o "Ver
      # histórico" da tela sem a metade que conta a história.
      #
      # A asserção é no bloco COM FALTA, e de propósito: o outro não tem linha de presença
      # nenhuma (criar e cancelar contam pela linha do bloco). E é `== 1`, não `> 0` — em Elixir
      # `nil > 0` é **verdadeiro** (átomo ordena depois de número), então a versão anterior
      # passava até com zero presenças.
      conn3 = build_conn() |> authed(ctx.owner) |> get("/api/audit?record_id=#{ctx.com_falta.id}")
      do_bloco = Enum.frequencies_by(json_response(conn3, 200)["entries"], & &1["resource"])
      assert do_bloco["attendance"] == 1

      conn2 = build_conn() |> authed(ctx.owner) |> get("/api/audit?user_id=#{ctx.owner.id}")
      assert %{"entries" => [_ | _]} = json_response(conn2, 200)
    end
  end
end
