defmodule ApiWeb.ProfessionalsControllerTest do
  @moduledoc """
  Endpoints do diretório de profissionais (fatia Profissionais). Integração real: sessão
  assinada + `LoadScope`, RBAC (leitura para todo membro, escrita só owner/admin), a escada
  401/403/404/422 e as superfícies de grade e exceções.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Directory

  defp email, do: "profc-#{System.unique_integer([:positive])}@example.com"

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

  defp active_member_session(owner, clinic, papel) do
    addr = email()

    {:ok, pending} =
      Accounts.invite_member_by_email(addr, %{papel: papel, clinic_id: clinic.id}, actor: owner)

    user = Accounts.get_user_by_email!(addr, authorize?: false)
    {:ok, _} = Accounts.accept_invite(pending, actor: user)
    sign_in(addr)
  end

  defp owner_with_clinic do
    owner = sign_in(email())

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp create_prof(clinic, nome \\ "Dra. Marina", overrides \\ %{}) do
    Directory.create_professional!(nome, overrides, tenant: clinic.id, authorize?: false)
  end

  setup %{conn: conn} do
    {owner, clinic} = owner_with_clinic()
    %{conn: authed(conn, owner), base_conn: conn, owner: owner, clinic: clinic}
  end

  describe "GET /api/professionals" do
    test "lista os profissionais e o expediente da clínica", %{conn: conn, clinic: clinic} do
      create_prof(clinic, "Dra. Marina", %{crefito: "C-1", sub: "Ortopedia"})

      body = conn |> get(~p"/api/professionals") |> json_response(200)

      assert [p] = body["professionals"]
      assert p["nome"] == "Dra. Marina"
      assert p["sub"] == "Ortopedia"
      # a grade vem carregada (vazia por ora) e o expediente da clínica vem junto.
      assert p["weekly_hours"] == []
      assert length(body["clinic_hours"]) == 7
    end

    test "o objeto não vaza clinic_id nem timestamps", %{conn: conn, clinic: clinic} do
      create_prof(clinic)
      body = conn |> get(~p"/api/professionals") |> json_response(200)
      [p | _] = body["professionals"]

      refute Map.has_key?(p, "clinic_id")
      refute Map.has_key?(p, "inserted_at")
    end
  end

  describe "POST /api/professionals" do
    test "cria com só o nome e devolve 201", %{conn: conn} do
      body =
        conn |> post(~p"/api/professionals", %{"nome" => "Dr. Novo"}) |> json_response(201)

      assert body["professional"]["nome"] == "Dr. Novo"
      assert body["professional"]["ativo"] == true
      assert body["professional"]["cor_indice"] == 1
    end

    test "nome vazio devolve 422", %{conn: conn} do
      body = conn |> post(~p"/api/professionals", %{"nome" => ""}) |> json_response(422)
      assert body["error"] == "invalid"
    end

    test "clinic_id no corpo é ignorado (vem do escopo)", %{conn: conn, clinic: clinic} do
      other = Ecto.UUID.generate()

      body =
        conn
        |> post(~p"/api/professionals", %{"nome" => "X", "clinic_id" => other})
        |> json_response(201)

      # foi criado na clínica do escopo, não na do corpo.
      prof =
        Directory.get_professional!(body["professional"]["id"],
          tenant: clinic.id,
          authorize?: false
        )

      assert prof.clinic_id == clinic.id
    end
  end

  describe "GET/PATCH /api/professionals/:id" do
    test "show traz a ficha com grade e exceções", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)
      body = conn |> get(~p"/api/professionals/#{prof.id}") |> json_response(200)

      assert body["professional"]["id"] == prof.id
      assert body["professional"]["weekly_hours"] == []
      assert body["professional"]["exceptions"] == []
    end

    test "update parcial", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)

      body =
        conn
        |> patch(~p"/api/professionals/#{prof.id}", %{"sub" => "Pilates", "cor_indice" => 4})
        |> json_response(200)

      assert body["professional"]["sub"] == "Pilates"
      assert body["professional"]["cor_indice"] == 4
    end

    test "id de outra clínica é 404", %{conn: conn} do
      {other_owner, other_clinic} = owner_with_clinic()
      alheio = create_prof(other_clinic)
      _ = other_owner

      assert conn |> get(~p"/api/professionals/#{alheio.id}") |> json_response(404)
    end
  end

  describe "deactivate / reactivate" do
    test "arquiva e reativa", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)

      body = conn |> post(~p"/api/professionals/#{prof.id}/deactivate") |> json_response(200)
      assert body["professional"]["ativo"] == false

      body = conn |> post(~p"/api/professionals/#{prof.id}/reactivate") |> json_response(200)
      assert body["professional"]["ativo"] == true
    end
  end

  describe "PATCH /api/professionals/:id/hours" do
    test "grava a grade com custom dentro do horário da clínica", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)

      body =
        conn
        |> patch(~p"/api/professionals/#{prof.id}/hours", %{
          "days" => [%{"dow" => 1, "modo" => "custom", "periods" => [["09:00", "11:00"]]}]
        })
        |> json_response(200)

      assert [%{"dow" => 1, "modo" => "custom", "periods" => [["09:00", "11:00"]]}] =
               body["hours"]
    end

    test "custom fora do horário da clínica é 422", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)

      body =
        conn
        |> patch(~p"/api/professionals/#{prof.id}/hours", %{
          "days" => [%{"dow" => 1, "modo" => "custom", "periods" => [["07:00", "09:00"]]}]
        })
        |> json_response(422)

      assert body["error"] == "invalid"
    end
  end

  describe "exceções de data do profissional" do
    test "cria e apaga uma folga", %{conn: conn, clinic: clinic} do
      prof = create_prof(clinic)

      created =
        conn
        |> post(~p"/api/professionals/#{prof.id}/exceptions", %{
          "data" => "2026-08-10",
          "nome" => "Férias",
          "tipo" => "fechado"
        })
        |> json_response(201)

      exc_id = created["exception"]["id"]
      assert created["exception"]["tipo"] == "fechado"

      assert conn
             |> delete(~p"/api/professionals/#{prof.id}/exceptions/#{exc_id}")
             |> response(204)
    end

    test "não apaga a exceção de um profissional pelo :id de outro (404, escopo por dono)",
         %{conn: conn, clinic: clinic} do
      p1 = create_prof(clinic, "P1")
      p2 = create_prof(clinic, "P2")

      created =
        conn
        |> post(~p"/api/professionals/#{p1.id}/exceptions", %{
          "data" => "2026-08-10",
          "tipo" => "fechado"
        })
        |> json_response(201)

      exc_id = created["exception"]["id"]

      # pelo endpoint de P2, a exceção de P1 é indistinguível de inexistente → 404
      assert conn |> delete(~p"/api/professionals/#{p2.id}/exceptions/#{exc_id}") |> response(404)
      # e continua existindo: apagar pelo dono certo funciona
      assert conn |> delete(~p"/api/professionals/#{p1.id}/exceptions/#{exc_id}") |> response(204)
    end
  end

  describe "RBAC e sessão" do
    test "sem sessão devolve 401", %{base_conn: conn} do
      assert conn |> get(~p"/api/professionals") |> json_response(401)
    end

    test "recepção lê mas não escreve", %{base_conn: base, owner: owner, clinic: clinic} do
      recep = active_member_session(owner, clinic, :recepcao)
      conn = authed(base, recep)

      assert conn |> get(~p"/api/professionals") |> json_response(200)
      assert conn |> post(~p"/api/professionals", %{"nome" => "X"}) |> json_response(403)
    end
  end
end
