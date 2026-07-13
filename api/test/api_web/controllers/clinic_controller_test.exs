defmodule ApiWeb.ClinicControllerTest do
  @moduledoc """
  Onboarding do primeiro acesso (POST /api/clinics). Integração real: sessão assinada +
  `LoadScope`, criação do tenant e do vínculo owner na mesma transação, e o `/me`
  passando a resolver a clínica recém-criada como tenant ativo (via default membership).
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts

  defp email, do: "user-#{System.unique_integer([:positive])}@example.com"

  # Sign-in de domínio (retorna o User com token de sessão em metadata).
  defp sign_in(addr) do
    :ok = Accounts.request_magic_link(addr)
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

  setup %{conn: conn} do
    user = sign_in(email())
    %{conn: authed(conn, user), base_conn: conn, user: user}
  end

  describe "POST /api/clinics" do
    test "cria a clínica e torna o usuário owner ativo", %{conn: conn, user: user} do
      body = conn |> post(~p"/api/clinics", %{nome: "Studio Movimento"}) |> json_response(201)

      assert %{"clinic" => %{"id" => id, "nome" => "Studio Movimento"}} = body
      assert is_binary(id)

      # o criador virou owner ATIVO da clínica recém-nascida (invariante ≥1 owner).
      assert [%{clinic_id: ^id, papel: :owner, status: :ativo}] =
               Accounts.list_active_memberships!(user.id, authorize?: false)
    end

    test "após o onboard, /api/auth/me resolve a nova clínica como tenant ativo", %{conn: conn} do
      %{"clinic" => %{"id" => id}} =
        conn |> post(~p"/api/clinics", %{nome: "Clínica X"}) |> json_response(201)

      # sem active_clinic_id na sessão, o LoadScope cai no único membership ativo (o novo).
      me = conn |> get(~p"/api/auth/me") |> json_response(200)
      assert me["active_clinic_id"] == id
      assert me["papel"] == "owner"
    end

    test "nome vazio devolve 422 (clínica sem nome é inválida)", %{conn: conn} do
      body = conn |> post(~p"/api/clinics", %{nome: ""}) |> json_response(422)
      assert body["error"] == "invalid"
    end

    test "nome ausente devolve 422", %{conn: conn} do
      body = conn |> post(~p"/api/clinics", %{}) |> json_response(422)
      assert body["error"] == "invalid"
    end

    test "nome absurdamente longo devolve 422 (limite no servidor, não só no client)", %{conn: conn} do
      body = conn |> post(~p"/api/clinics", %{nome: String.duplicate("A", 300)}) |> json_response(422)
      assert body["error"] == "invalid"
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> post(~p"/api/clinics", %{nome: "X"}) |> json_response(401)
    end
  end
end
