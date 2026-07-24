defmodule ApiWeb.AppointmentsControllerTest do
  @moduledoc """
  Endpoints da agenda (doc 25 §5). Integração real: sessão + `LoadScope`, o RBAC de A8 e a
  escada 401/403/422 — com atenção especial ao **`code` estável** no 422, que é o canal por
  onde a UI descobre que pode oferecer "marcar como encaixe" (A10).
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records

  @segunda "2026-07-20"

  defp email, do: "appt-#{System.unique_integer([:positive])}@example.com"

  defp sign_in(addr) do
    :ok = Accounts.request_magic_link(addr, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)
    user
  end

  defp authed(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp member_session(owner, clinic, papel, professional_id \\ nil) do
    addr = email()

    attrs = %{papel: papel, clinic_id: clinic.id, professional_id: professional_id}

    {:ok, pending} = Accounts.invite_member_by_email(addr, attrs, actor: owner)

    user = Accounts.get_user_by_email!(addr, authorize?: false)
    {:ok, _} = Accounts.accept_invite(pending, actor: user)
    sign_in(addr)
  end

  defp fixture do
    owner = sign_in(email())

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

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
    %{owner: owner, clinic: clinic, prof: prof, tipo: tipo, paciente: paciente}
  end

  defp payload(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        # 08:00 em São Paulo (UTC-3) na segunda de referência.
        "starts_at" => "2026-07-20T11:00:00Z",
        "professional_id" => ctx.prof.id,
        "appointment_type_id" => ctx.tipo.id,
        "patient_ids" => [ctx.paciente.id]
      },
      overrides
    )
  end

  describe "POST /api/appointments" do
    test "cria e devolve 201", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> post("/api/appointments", payload(ctx))

      assert %{"appointment" => appt} = json_response(conn, 201)
      assert appt["status"] == "agendado"
      assert appt["patient_ids"] == [ctx.paciente.id]
      # `ends_at` é derivado, não veio do corpo.
      assert appt["ends_at"] == "2026-07-20T11:50:00Z"
    end

    test "sem sessão é 401", %{conn: conn} do
      ctx = fixture()
      conn = post(conn, "/api/appointments", payload(ctx))
      assert json_response(conn, 401)
    end

    test "CONFLITO devolve 422 com code schedule_conflict e SEM campo (A10)", %{conn: conn} do
      ctx = fixture()
      conn |> authed(ctx.owner) |> post("/api/appointments", payload(ctx))

      conn =
        conn
        |> authed(ctx.owner)
        |> post("/api/appointments", payload(ctx, %{"starts_at" => "2026-07-20T11:30:00Z"}))

      body = json_response(conn, 422)
      assert body["code"] == "schedule_conflict"
      # Pintar `starts_at` de vermelho mentiria: o horário está certo, o mundo é que mudou.
      assert [%{"field" => nil}] = body["details"]
    end

    test "fora do expediente devolve 422 com code outside_business_hours", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        # 22:00 local.
        |> post("/api/appointments", payload(ctx, %{"starts_at" => "2026-07-21T01:00:00Z"}))

      body = json_response(conn, 422)
      assert body["code"] == "outside_business_hours"
    end

    test "recepção PODE agendar (A8)", %{conn: conn} do
      ctx = fixture()
      recepcao = member_session(ctx.owner, ctx.clinic, :recepcao)

      conn = conn |> authed(recepcao) |> post("/api/appointments", payload(ctx))
      assert json_response(conn, 201)
    end

    # O doc 25 §7 fixa **403** (e não 422) para as duas: a recusa é de autorização, não de
    # dado — o horário está certo, quem pediu é que não pode.
    test "profissional recebe 403 ao pedir ENCAIXE (A9)", %{conn: conn} do
      ctx = fixture()
      prof_user = member_session(ctx.owner, ctx.clinic, :profissional, ctx.prof.id)

      conn =
        conn
        |> authed(prof_user)
        |> post("/api/appointments", payload(ctx, %{"encaixe" => true}))

      assert json_response(conn, 403)
    end

    test "profissional recebe 403 ao agendar na coluna do colega (A7)", %{conn: conn} do
      ctx = fixture()

      colega =
        Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      prof_user = member_session(ctx.owner, ctx.clinic, :profissional, ctx.prof.id)

      conn =
        conn
        |> authed(prof_user)
        |> post("/api/appointments", payload(ctx, %{"professional_id" => colega.id}))

      assert json_response(conn, 403)
    end

    test "paciente de OUTRA clínica devolve 422, não 201", %{conn: conn} do
      ctx = fixture()
      outra = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> post("/api/appointments", payload(ctx, %{"patient_ids" => [outra.paciente.id]}))

      assert json_response(conn, 422)
    end
  end

  describe "GET /api/appointments" do
    test "devolve agendamentos, profissionais, tipos e o agora do servidor", %{conn: conn} do
      ctx = fixture()
      conn |> authed(ctx.owner) |> post("/api/appointments", payload(ctx))

      conn = conn |> authed(ctx.owner) |> get("/api/appointments?from=#{@segunda}")
      body = json_response(conn, 200)

      assert [appt] = body["appointments"]
      assert appt["professional_id"] == ctx.prof.id
      assert [_] = body["professionals"]
      assert [_ | _] = body["appointment_types"]

      # Sem o sidecar de pacientes o bloco não tem como escrever o nome de quem vai ser
      # atendido — mostraria o nome do tipo ("Sessão") no lugar da pessoa.
      assert [%{"nome" => "Paciente"}] = body["patients"]
      # A linha do "agora" não pode depender do relógio do browser.
      assert is_binary(body["agora"])
      assert body["timezone"] == "America/Sao_Paulo"
    end

    test "o agendamento das 23h local NÃO vaza para o dia seguinte", %{conn: conn} do
      ctx = fixture()

      # Expediente até 18:00; usamos um horário dentro dele mas perto do fim do dia UTC.
      # 17:00 local = 20:00Z, mesmo dia UTC — o caso interessante é a janela: pedir o dia 20
      # deve trazer, e pedir o 21 não.
      conn
      |> authed(ctx.owner)
      |> post("/api/appointments", payload(ctx, %{"starts_at" => "2026-07-20T20:00:00Z"}))

      dia20 = conn |> authed(ctx.owner) |> get("/api/appointments?from=2026-07-20")
      assert [_] = json_response(dia20, 200)["appointments"]

      dia21 = conn |> authed(ctx.owner) |> get("/api/appointments?from=2026-07-21")
      assert [] == json_response(dia21, 200)["appointments"]
    end

    test "janela maior que 31 dias é 422", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get("/api/appointments?from=2026-01-01&to=2026-12-31")

      assert json_response(conn, 422)
    end

    test "data malformada é 422", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/appointments?from=ontem")
      assert json_response(conn, 422)
    end
  end

  describe "GET /api/appointments/counts" do
    # As visões Semana e Mês (doc 25 §9, Entrega 2). A quebra é por **dia × profissional**
    # (B-D2): ocultar alguém na sidebar é filtro de cliente, e sem a quebra a barra da semana
    # não mexeria — a Semana passaria a discordar do Dia sobre o mesmo dia.
    test "conta por dia e por profissional, com ocupação e capacidade", %{conn: conn} do
      ctx = fixture()
      conn |> authed(ctx.owner) |> post("/api/appointments", payload(ctx))

      conn =
        conn
        |> authed(ctx.owner)
        |> get("/api/appointments/counts?from=#{@segunda}&to=2026-07-21")

      body = json_response(conn, 200)
      assert [segunda, terca] = body["days"]

      assert segunda["date"] == @segunda
      assert [%{"professional_id" => pid} = linha] = segunda["professionals"]
      assert pid == ctx.prof.id
      assert linha["total"] == 1

      # A duração do tipo é 50 min; a capacidade é o expediente real do dia (08–12 e 13–18).
      assert linha["ocupado_minutos"] == 50
      assert linha["capacidade_minutos"] == 540

      # Dia sem nada ainda aparece — com capacidade, que é o denominador da barra.
      assert [%{"total" => 0, "ocupado_minutos" => 0, "capacidade_minutos" => 540}] =
               terca["professionals"]
    end

    # A barra lateral (onde se OCULTA profissional) é a mesma nas quatro visões, e é ela que
    # alimenta o filtro que B-D2 existe para honrar. Sem os profissionais aqui, o toggle some
    # justamente em Semana e Mês — pego na verificação ao vivo, não pelos testes.
    test "devolve os profissionais, como a leitura do dia", %{conn: conn} do
      ctx = fixture()

      conn = conn |> authed(ctx.owner) |> get("/api/appointments/counts?from=#{@segunda}")

      assert %{"professionals" => [prof]} = json_response(conn, 200)
      assert prof["id"] == ctx.prof.id
      assert prof["nome"] == "Dra. X"
    end

    test "dia fechado vem com capacidade zero, e não some da lista", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        # 2026-07-19 é domingo, e o expediente semeado fecha domingo.
        |> get("/api/appointments/counts?from=2026-07-19&to=2026-07-19")

      assert %{"days" => [domingo]} = json_response(conn, 200)
      assert [%{"capacidade_minutos" => 0}] = domingo["professionals"]
    end

    # Mesma regra de `ocupaGrade` (doc 25 §7): cancelado não disputa espaço, então não conta
    # nem no numerador da ocupação nem no "N agend." do cartão.
    test "cancelado não entra na contagem nem nos minutos", %{conn: conn} do
      ctx = fixture()
      criar = conn |> authed(ctx.owner) |> post("/api/appointments", payload(ctx))
      %{"appointment" => %{"id" => id}} = json_response(criar, 201)

      # Não há ação de cancelar nesta fatia (é a Entrega 4): a coluna é escrita direto, como
      # no teste da constraint em `appointment_test.exs:459`.
      Api.Repo.query!("UPDATE appointments SET status = 'cancelado' WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

      conn = conn |> authed(ctx.owner) |> get("/api/appointments/counts?from=#{@segunda}")

      assert %{"days" => [dia]} = json_response(conn, 200)
      assert [%{"total" => 0, "ocupado_minutos" => 0}] = dia["professionals"]
    end

    # A7 + P1 (2026-07-21): o recorte da leitura do dia vale aqui, e a decisão P1 fechou a
    # pergunta que estava aberta — o papel `profissional` só vê a **própria** linha. O colega
    # não aparece nem como coluna zerada: a lista de profissionais que alimenta a contagem é a
    # mesma `list_professionals!` recortada por `OwnProfessionalOnly`, então Dia, Semana e Mês
    # concordam (só o próprio) por construção, sem recorte à parte no endpoint de agregação.
    test "profissional só vê a própria linha; a do colega nem aparece (A7/P1)", %{conn: conn} do
      ctx = fixture()

      outro =
        Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      prof_user = member_session(ctx.owner, ctx.clinic, :profissional, ctx.prof.id)

      conn
      |> authed(ctx.owner)
      |> post("/api/appointments", payload(ctx, %{"professional_id" => outro.id}))

      conn |> authed(ctx.owner) |> post("/api/appointments", payload(ctx))

      conn = conn |> authed(prof_user) |> get("/api/appointments/counts?from=#{@segunda}")

      assert %{"days" => [dia]} = json_response(conn, 200)
      por_id = Map.new(dia["professionals"], &{&1["professional_id"], &1})

      assert por_id[ctx.prof.id]["total"] == 1

      # O colega some inteiro — nem linha zerada. Sua escala é dado recortado, não só sua agenda.
      assert por_id[outro.id] == nil
      assert map_size(por_id) == 1
    end

    test "sem sessão é 401", %{conn: conn} do
      fixture()
      conn = get(conn, "/api/appointments/counts?from=#{@segunda}")
      assert json_response(conn, 401)
    end

    # O irmão do teto de `/availability` (doc 26 §7). Esta é a leitura que a visão Mês faz por
    # padrão, com 31 dias e a clínica inteira: ela agrega em MEMÓRIA sobre uma leitura só, e é
    # exatamente isso que o teto protege. Se alguém trocar o agrupamento por um laço de
    # `Availability.day_periods/3` por dia, ou reintroduzir uma leitura por profissional, a
    # conta salta e este teste acusa — o resultado na tela seria idêntico.
    #
    # Generoso de propósito: fixa a ORDEM DE GRANDEZA (dezenas, não centenas), não o número
    # exato, que muda com refactor legítimo.
    test "o custo não cresce com a janela nem com o nº de profissionais", %{conn: conn} do
      ctx = fixture()

      Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)
      Directory.create_professional!("Dr. Z", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      # Uma requisição antes de medir: o fuso da clínica é cacheado (D-K) e a PRIMEIRA leitura
      # da clínica-nova paga a falta. Sem esta, a comparação mediria o aquecimento do cache
      # (a janela medida primeiro sairia uma query mais cara) em vez do custo da janela.
      conn |> authed(ctx.owner) |> get("/api/appointments/counts?from=#{@segunda}")

      um_dia =
        count_queries(fn ->
          conn
          |> authed(ctx.owner)
          |> get("/api/appointments/counts?from=#{@segunda}")
          |> json_response(200)
        end)

      trinta_dias =
        count_queries(fn ->
          conn
          |> authed(ctx.owner)
          |> get("/api/appointments/counts?from=2026-07-01&to=2026-07-31")
          |> json_response(200)
        end)

      assert trinta_dias == um_dia,
             "31 dias custou #{trinta_dias} queries e 1 dia custou #{um_dia}: o custo passou a acompanhar a janela"

      assert trinta_dias < 30,
             "#{trinta_dias} queries para uma leitura de contagens — o agrupamento voltou a ser por dia?"
    end

    test "janela maior que 31 dias é 422", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get("/api/appointments/counts?from=2026-01-01&to=2026-12-31")

      assert json_response(conn, 422)
    end
  end

  describe "GET /api/availability" do
    # A resposta é SEMPRE `professionals: [...]`, com um item por profissional pedido — mesmo
    # quando se pede um só. A forma anterior (`days:` na raiz) servia a um único profissional e
    # obrigava o BFF a um fan-out de uma requisição por coluna (achado (f) do doc 26); admitir
    # as duas formas conforme a quantidade repetiria o defeito que o teste do 422 abaixo existe
    # para impedir — o mesmo endpoint respondendo em dois formatos.
    test "devolve os períodos do dia", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get("/api/availability?professional_id=#{ctx.prof.id}&date_from=#{@segunda}")

      assert %{"professionals" => [%{"professional_id" => pid, "days" => [day]}]} =
               json_response(conn, 200)

      assert pid == ctx.prof.id
      assert day["date"] == @segunda
      assert day["periods"] == [["08:00", "12:00"], ["13:00", "18:00"]]
    end

    test "domingo vem fechado com motivo", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get("/api/availability?professional_id=#{ctx.prof.id}&date_from=2026-07-19")

      assert %{"professionals" => [%{"days" => [day]}]} = json_response(conn, 200)
      assert day["periods"] == []
      assert day["closed_reason"] == "clinica_fechada"
    end

    test "vários profissionais numa requisição só, na ordem pedida", %{conn: conn} do
      ctx = fixture()

      outro =
        Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      conn =
        conn
        |> authed(ctx.owner)
        |> get(
          "/api/availability?professional_id=#{ctx.prof.id},#{outro.id}&date_from=#{@segunda}"
        )

      assert %{"professionals" => [a, b]} = json_response(conn, 200)
      assert a["professional_id"] == ctx.prof.id
      assert b["professional_id"] == outro.id
      assert a["days"] |> hd() |> Map.get("periods") == [["08:00", "12:00"], ["13:00", "18:00"]]
    end

    # P1 (2026-07-21): a lista recortada esconde o colega, mas este endpoint aceita
    # `professional_id` explícito e lê as fontes com `authorize?: false` — sem guarda, um
    # profissional sondaria a disponibilidade do colega direto pela URL (a RLS só garante
    # mesma-clínica, não mesmo-profissional). O recorte fecha no controller, onde o escopo é
    # conhecido: para o profissional, o id do colega é indistinguível de inexistente → 404.
    test "P1: profissional NÃO consulta a disponibilidade do colega (404)", %{conn: conn} do
      ctx = fixture()

      outro =
        Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      prof_user = member_session(ctx.owner, ctx.clinic, :profissional, ctx.prof.id)

      # A própria: 200.
      ok =
        conn
        |> authed(prof_user)
        |> get("/api/availability?professional_id=#{ctx.prof.id}&date_from=#{@segunda}")

      assert %{"professionals" => [%{"professional_id" => pid}]} = json_response(ok, 200)
      assert pid == ctx.prof.id

      # A do colega (sozinha ou junto da própria): 404, não vaza coluna.
      for ids <- ["#{outro.id}", "#{ctx.prof.id},#{outro.id}"] do
        resp =
          conn
          |> authed(prof_user)
          |> get("/api/availability?professional_id=#{ids}&date_from=#{@segunda}")

        assert json_response(resp, 404)
      end
    end

    test "professional_id repetido na query também vale", %{conn: conn} do
      ctx = fixture()

      outro =
        Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      conn =
        conn
        |> authed(ctx.owner)
        |> get(
          "/api/availability?professional_id[]=#{ctx.prof.id}&professional_id[]=#{outro.id}" <>
            "&date_from=#{@segunda}"
        )

      assert %{"professionals" => [_, _]} = json_response(conn, 200)
    end

    # O achado (f) do doc 26, virado teste: eram 254 queries para 30 dias, porque as fontes
    # eram recarregadas POR DIA e `render_days/3` ainda fazia uma sonda que descartava. O custo
    # agora não acompanha nem o nº de dias nem o nº de profissionais — é o mesmo punhado de
    # leituras sempre. O teto é generoso de propósito: fixa a ORDEM DE GRANDEZA (dezenas, não
    # centenas), não a contagem exata, que muda com refactor legítimo.
    test "o custo não cresce com a janela nem com o nº de profissionais", %{conn: conn} do
      ctx = fixture()

      outro =
        Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)

      ids = "#{ctx.prof.id},#{outro.id}"

      um_dia =
        count_queries(fn ->
          conn
          |> authed(ctx.owner)
          |> get("/api/availability?professional_id=#{ctx.prof.id}&date_from=#{@segunda}")
          |> json_response(200)
        end)

      trinta_dias =
        count_queries(fn ->
          conn
          |> authed(ctx.owner)
          |> get(
            "/api/availability?professional_id=#{ids}&date_from=2026-07-01&date_to=2026-07-30"
          )
          |> json_response(200)
        end)

      assert trinta_dias <= um_dia + 2,
             "30 dias × 2 profissionais custou #{trinta_dias} queries contra #{um_dia} de 1 dia × 1 profissional"

      assert trinta_dias < 30, "#{trinta_dias} queries ainda escala com a janela"
    end

    # Achado (g) do doc 26: eram 5 SELECTs idênticos em `memberships` por request, um por
    # avaliação de policy. Hoje a membership é resolvida UMA vez (pelo `LoadScope`) e reusada
    # via `Api.Accounts.ActiveMembership`.
    #
    # O teto de 2 não é folga arbitrária: é o que sobra se um caminho voltar a não receber o
    # escopo. Foi assim que se descobriu que a query de `load:` de relacionamento não herda o
    # contexto da query de cima — só `:shared` — e que por isso o `OwnAgendaOnly` rodava ali
    # sem escopo, sem filtrar. Este teste é o que impede essa propagação de sumir calada.
    test "a membership é resolvida uma vez por request, não a cada policy", %{conn: conn} do
      ctx = fixture()

      n =
        count_queries(
          fn ->
            conn
            |> authed(ctx.owner)
            |> get("/api/appointments?from=#{@segunda}&to=#{@segunda}")
            |> json_response(200)
          end,
          "memberships"
        )

      assert n <= 2, "#{n} leituras de memberships — o escopo deixou de ser reusado"
    end

    test "um profissional inexistente na lista é 404", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get(
          "/api/availability?professional_id=#{ctx.prof.id},#{Ecto.UUID.generate()}" <>
            "&date_from=#{@segunda}"
        )

      assert json_response(conn, 404)
    end

    test "sem professional_id é 422", %{conn: conn} do
      ctx = fixture()
      conn = conn |> authed(ctx.owner) |> get("/api/availability?date_from=#{@segunda}")
      assert json_response(conn, 422)
    end

    test "data malformada é 422", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get("/api/availability?professional_id=#{ctx.prof.id}&date_from=amanha")

      assert json_response(conn, 422)
    end

    test "janela maior que 31 dias é 422", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get(
          "/api/availability?professional_id=#{ctx.prof.id}&date_from=2026-01-01&date_to=2026-12-31"
        )

      assert json_response(conn, 422)
    end

    test "date_to anterior a date_from é 422", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get(
          "/api/availability?professional_id=#{ctx.prof.id}&date_from=2026-07-20&date_to=2026-07-10"
        )

      assert json_response(conn, 422)
    end

    # Fixa o formato do 422 depois de unificar as cinco fontes numa só
    # (`TenantScope.unprocessable/2`). Antes disto, o `invalid/2` privado de cada controller
    # nunca emitia `code` e a função compartilhada sempre emitia — o MESMO endpoint respondia
    # em dois formatos conforme o caminho que falhasse. O contrato escolhido: a forma base é
    # `error` + `details`, e `code` é **opcional**, presente só quando o erro nomeia um código
    # (A10). Sem esta asserção, uma regressão que passasse a mandar `code: null` em todo 422
    # (ou que sumisse com ele no conflito) passaria calada.
    test "422 de parâmetro tem a forma base, sem `code`", %{conn: conn} do
      ctx = fixture()

      requisicoes = [
        "/api/availability?professional_id=#{ctx.prof.id}&date_from=amanha",
        "/api/availability?date_from=#{@segunda}",
        "/api/appointments?from=ontem",
        "/api/appointments?from=2026-01-01&to=2026-12-31"
      ]

      for rota <- requisicoes do
        body = conn |> authed(ctx.owner) |> get(rota) |> json_response(422)

        assert body["error"] == "invalid"
        assert [%{"field" => nil, "message" => mensagem}] = body["details"]
        assert is_binary(mensagem) and mensagem != ""
        refute Map.has_key?(body, "code")
      end
    end

    test "intervalo de vários dias devolve um item por dia", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get(
          "/api/availability?professional_id=#{ctx.prof.id}&date_from=2026-07-20&date_to=2026-07-22"
        )

      assert %{"professionals" => [%{"days" => days}]} = json_response(conn, 200)
      assert length(days) == 3
    end

    test "profissional inexistente é 404", %{conn: conn} do
      ctx = fixture()
      fake = Ecto.UUID.generate()

      conn =
        conn
        |> authed(ctx.owner)
        |> get("/api/availability?professional_id=#{fake}&date_from=#{@segunda}")

      assert json_response(conn, 404)
    end
  end

  # Cria um bloco via HTTP e devolve `{id, version}` — o `version` é o que o guard de 409 exige.
  defp create_appt(conn, ctx, overrides \\ %{}) do
    resp = conn |> authed(ctx.owner) |> post("/api/appointments", payload(ctx, overrides))
    appt = json_response(resp, 201)["appointment"]
    {appt["id"], appt["version"]}
  end

  describe "ciclo de vida (Entrega 4)" do
    test "PATCH reschedule move o bloco e avança a versão", %{conn: conn} do
      ctx = fixture()
      {id, version} = create_appt(conn, ctx)

      resp =
        conn
        |> authed(ctx.owner)
        |> patch("/api/appointments/#{id}/reschedule", %{
          "starts_at" => "2026-07-20T12:00:00Z",
          "expected_version" => version
        })

      appt = json_response(resp, 200)["appointment"]
      assert appt["starts_at"] == "2026-07-20T12:00:00Z"
      assert appt["version"] == version + 1
    end

    test "reschedule para fora do expediente → 422 outside_business_hours (GAP-03)", %{conn: conn} do
      ctx = fixture()
      {id, version} = create_appt(conn, ctx)

      resp =
        conn
        |> authed(ctx.owner)
        # 12:30 local cai no almoço.
        |> patch("/api/appointments/#{id}/reschedule", %{
          "starts_at" => "2026-07-20T15:30:00Z",
          "expected_version" => version
        })

      assert json_response(resp, 422)["code"] == "outside_business_hours"
    end

    test "reschedule sobre outro bloco → 422 schedule_conflict SEM campo (A10)", %{conn: conn} do
      ctx = fixture()
      create_appt(conn, ctx, %{"starts_at" => "2026-07-20T12:00:00Z"})
      {id, version} = create_appt(conn, ctx)

      resp =
        conn
        |> authed(ctx.owner)
        |> patch("/api/appointments/#{id}/reschedule", %{
          "starts_at" => "2026-07-20T12:00:00Z",
          "expected_version" => version
        })

      body = json_response(resp, 422)
      assert body["code"] == "schedule_conflict"
      assert [%{"field" => nil}] = body["details"]
    end

    test "expected_version obsoleto → 409 version_conflict", %{conn: conn} do
      ctx = fixture()
      {id, version} = create_appt(conn, ctx)

      resp =
        conn
        |> authed(ctx.owner)
        |> post("/api/appointments/#{id}/cancel", %{"expected_version" => version + 5})

      body = json_response(resp, 409)
      assert body["code"] == "version_conflict"
    end

    test "POST cancel com motivo preserva o registro", %{conn: conn} do
      ctx = fixture()
      {id, version} = create_appt(conn, ctx)

      resp =
        conn
        |> authed(ctx.owner)
        |> post("/api/appointments/#{id}/cancel", %{
          "cancel_reason" => "paciente pediu",
          "expected_version" => version
        })

      appt = json_response(resp, 200)["appointment"]
      assert appt["status"] == "cancelado"
      assert appt["cancel_reason"] == "paciente pediu"
    end

    test "POST reopen devolve o bloco a agendado", %{conn: conn} do
      ctx = fixture()
      {id, v0} = create_appt(conn, ctx)

      conn
      |> authed(ctx.owner)
      |> post("/api/appointments/#{id}/cancel", %{"expected_version" => v0})

      resp = conn |> authed(ctx.owner) |> post("/api/appointments/#{id}/reopen", %{})
      assert json_response(resp, 200)["appointment"]["status"] == "agendado"
    end

    test "POST justify-absence marca o selo", %{conn: conn} do
      ctx = fixture()
      {id, _} = create_appt(conn, ctx)

      # Só se justifica uma falta de verdade (F4/doc 34): marca faltou antes de justificar.
      # O bloco de referência é 20/07 (passado), então o gate `SessionStarted` já liberou.
      conn |> authed(ctx.owner) |> post("/api/appointments/#{id}/miss", %{})

      resp =
        conn
        |> authed(ctx.owner)
        |> post("/api/appointments/#{id}/justify-absence", %{"justificada" => true})

      assert json_response(resp, 200)["appointment"]["falta_justificada"] == true
    end

    test "POST exclude some com o bloco da leitura (soft-delete, doc 40)", %{conn: conn} do
      ctx = fixture()
      {id, version} = create_appt(conn, ctx)

      resp =
        conn
        |> authed(ctx.owner)
        |> post("/api/appointments/#{id}/exclude", %{"expected_version" => version})

      # O 200 confirma a exclusão; o `excluded_at` NÃO viaja no bloco (o cliente remove por id, via
      # o evento `appointment_excluded` do canal — não inspecionando o campo).
      assert json_response(resp, 200)["appointment"]["id"] == id

      # O contrato de verdade: o GET da janela não lista mais o bloco.
      body =
        conn
        |> authed(ctx.owner)
        |> get("/api/appointments?from=#{@segunda}")
        |> json_response(200)

      assert body["appointments"] == []
    end

    test "POST exclude num bloco que aconteceu (concluído) → 422", %{conn: conn} do
      ctx = fixture()
      {id, _version} = create_appt(conn, ctx)

      # O bloco de referência é 20/07 (passado): o gate `SessionStarted` já liberou concluir.
      conn |> authed(ctx.owner) |> post("/api/appointments/#{id}/complete", %{})

      resp = conn |> authed(ctx.owner) |> post("/api/appointments/#{id}/exclude", %{})
      assert json_response(resp, 422)
    end

    test "transição em bloco inexistente → 404", %{conn: conn} do
      ctx = fixture()
      fake = Ash.UUID.generate()

      for path <- ["complete", "miss", "reopen", "exclude"] do
        resp = conn |> authed(ctx.owner) |> post("/api/appointments/#{fake}/#{path}", %{})
        assert json_response(resp, 404)
      end
    end

    test "sem sessão → 401", %{conn: conn} do
      ctx = fixture()
      {id, _} = create_appt(conn, ctx)
      assert conn |> post("/api/appointments/#{id}/cancel", %{}) |> json_response(401)
    end
  end

  # Sem medir, "otimizei" é alegação — o teto no teste é o que impede a regressão voltar calada.
  defp count_queries(fun, source \\ nil) do
    {_result, n} = Api.QueryCounter.count(fun, source)
    n
  end
end
