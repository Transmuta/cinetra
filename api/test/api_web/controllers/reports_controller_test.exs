defmodule ApiWeb.ReportsControllerTest do
  @moduledoc """
  `GET /api/reports/summary` (doc 33, Fatia 9): o agregado de período da tela de Relatórios.
  Integração real — sessão + `LoadScope`, o wire (totais/quebras/profissionais/tipos) e o
  recorte do papel `profissional` chegando pela mesma preparation da agenda.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Directory
  alias Api.Records

  @segunda "2026-07-20"

  defp email, do: "reports-#{System.unique_integer([:positive])}@example.com"

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

  # Cria um agendamento via HTTP (mesmo caminho da agenda). `starts_at` em UTC = 08:00 SP.
  defp create_appt(conn, ctx, user, starts_at, professional_id \\ nil) do
    payload = %{
      "starts_at" => starts_at,
      "professional_id" => professional_id || ctx.prof.id,
      "appointment_type_id" => ctx.tipo.id,
      "patient_ids" => [ctx.paciente.id]
    }

    conn |> authed(user) |> post("/api/appointments", payload) |> json_response(201)
  end

  defp get_summary(conn, user, params) do
    conn
    |> authed(user)
    |> get("/api/reports/summary?" <> URI.encode_query(params))
  end

  describe "GET /api/reports/summary" do
    test "devolve o agregado do período com os totais, quebras, profissionais e tipos", %{conn: conn} do
      ctx = fixture()
      create_appt(conn, ctx, ctx.owner, "2026-07-20T11:00:00Z")
      create_appt(conn, ctx, ctx.owner, "2026-07-20T12:00:00Z")

      body =
        get_summary(conn, ctx.owner, %{"date_from" => @segunda, "date_to" => @segunda})
        |> json_response(200)

      assert body["range"] == %{"from" => @segunda, "to" => @segunda}
      assert body["totals"]["atendimentos"] == 2
      assert body["totals"]["futuros"] == 2
      assert body["totals"]["capacidade_minutos"] == 540
      assert [%{"date" => @segunda, "total" => 2}] = body["por_dia"]
      assert [%{"professional_id" => pid, "total" => 2}] = body["por_profissional"]
      assert pid == ctx.prof.id
      assert Enum.any?(body["professionals"], &(&1["id"] == ctx.prof.id))
      assert Enum.any?(body["appointment_types"], &(&1["id"] == ctx.tipo.id))
      assert body["timezone"] == "America/Sao_Paulo"
    end

    test "sem sessão é 401", %{conn: conn} do
      conn = get(conn, "/api/reports/summary?date_from=#{@segunda}&date_to=#{@segunda}")
      assert json_response(conn, 401)
    end

    test "janela invertida devolve 422", %{conn: conn} do
      ctx = fixture()

      conn =
        get_summary(conn, ctx.owner, %{"date_from" => "2026-07-21", "date_to" => "2026-07-20"})

      assert json_response(conn, 422)
    end

    test "recepção enxerga a clínica inteira", %{conn: conn} do
      ctx = fixture()
      create_appt(conn, ctx, ctx.owner, "2026-07-20T11:00:00Z")
      recepcao = member_session(ctx.owner, ctx.clinic, :recepcao)

      body =
        get_summary(conn, recepcao, %{"date_from" => @segunda, "date_to" => @segunda})
        |> json_response(200)

      assert body["totals"]["atendimentos"] == 1
    end

    test "profissional só vê a própria agenda (recorte de dados, não 403)", %{conn: conn} do
      ctx = fixture()
      outro = Directory.create_professional!("Dr. Y", %{}, tenant: ctx.clinic.id, actor: ctx.owner)
      create_appt(conn, ctx, ctx.owner, "2026-07-20T11:00:00Z", ctx.prof.id)

      # Vinculado a `outro`, não enxerga o agendamento da Dra. X.
      prof_user = member_session(ctx.owner, ctx.clinic, :profissional, outro.id)

      body =
        get_summary(conn, prof_user, %{"date_from" => @segunda, "date_to" => @segunda})
        |> json_response(200)

      assert body["totals"]["atendimentos"] == 0
      assert Enum.map(body["professionals"], & &1["id"]) == [outro.id]
    end
  end
end
