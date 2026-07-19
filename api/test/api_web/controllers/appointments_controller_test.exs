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

  describe "GET /api/availability" do
    test "devolve os períodos do dia", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get("/api/availability?professional_id=#{ctx.prof.id}&date_from=#{@segunda}")

      assert %{"days" => [day]} = json_response(conn, 200)
      assert day["date"] == @segunda
      assert day["periods"] == [["08:00", "12:00"], ["13:00", "18:00"]]
    end

    test "domingo vem fechado com motivo", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get("/api/availability?professional_id=#{ctx.prof.id}&date_from=2026-07-19")

      assert %{"days" => [day]} = json_response(conn, 200)
      assert day["periods"] == []
      assert day["closed_reason"] == "clinica_fechada"
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

    test "intervalo de vários dias devolve um item por dia", %{conn: conn} do
      ctx = fixture()

      conn =
        conn
        |> authed(ctx.owner)
        |> get(
          "/api/availability?professional_id=#{ctx.prof.id}&date_from=2026-07-20&date_to=2026-07-22"
        )

      assert %{"days" => days} = json_response(conn, 200)
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
end
