defmodule ApiWeb.ClinicControllerTest do
  @moduledoc """
  Onboarding do primeiro acesso (POST /api/clinics). Integração real: sessão assinada +
  `LoadScope`, criação do tenant e do vínculo owner na mesma transação, e o `/me`
  passando a resolver a clínica recém-criada como tenant ativo (via default membership).
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts

  defp owner_with_clinic do
    owner = sign_in!(email_unico("user"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  setup %{conn: conn} do
    user = sign_in!(email_unico("user"))
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

    test "nome absurdamente longo devolve 422 (limite no servidor, não só no client)", %{
      conn: conn
    } do
      body =
        conn |> post(~p"/api/clinics", %{nome: String.duplicate("A", 300)}) |> json_response(422)

      assert body["error"] == "invalid"
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> post(~p"/api/clinics", %{nome: "X"}) |> json_response(401)
    end
  end

  describe "GET /api/clinic" do
    test "membro lê nome, CNPJ e endereço da clínica ativa", %{base_conn: base_conn} do
      {owner, _clinic} = owner_with_clinic()

      body = base_conn |> authed(owner) |> get(~p"/api/clinic") |> json_response(200)
      assert %{"clinic" => %{"nome" => nome, "cnpj" => nil, "endereco" => nil}} = body
      assert is_binary(nome)
    end

    test "recepção também lê (leitura para todo membro)", %{base_conn: base_conn} do
      {owner, clinic} = owner_with_clinic()
      recep = sessao_de_membro!(owner, clinic, :recepcao)

      body = base_conn |> authed(recep) |> get(~p"/api/clinic") |> json_response(200)
      assert body["clinic"]["id"] == clinic.id
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> get(~p"/api/clinic") |> json_response(401)
    end

    test "autenticado sem clínica ativa devolve 403", %{base_conn: base_conn} do
      orphan = sign_in!(email_unico("user"))
      assert base_conn |> authed(orphan) |> get(~p"/api/clinic") |> json_response(403)
    end
  end

  describe "PATCH /api/clinic" do
    test "owner edita nome, CNPJ (mascarado) e endereço; resposta traz o CNPJ normalizado", %{
      base_conn: base_conn
    } do
      {owner, _clinic} = owner_with_clinic()

      body =
        base_conn
        |> authed(owner)
        |> patch(~p"/api/clinic", %{
          nome: "Clínica Vida",
          cnpj: "12.ABC.345/01DE-35",
          endereco: "Rua X, 100 · SP"
        })
        |> json_response(200)

      assert body["clinic"]["nome"] == "Clínica Vida"
      assert body["clinic"]["cnpj"] == "12ABC34501DE35"
      assert body["clinic"]["endereco"] == "Rua X, 100 · SP"
    end

    test "CNPJ inválido devolve 422 apontando o campo", %{base_conn: base_conn} do
      {owner, _clinic} = owner_with_clinic()

      body =
        base_conn
        |> authed(owner)
        |> patch(~p"/api/clinic", %{cnpj: "12ABC34501DE34"})
        |> json_response(422)

      assert body["error"] == "invalid"
      assert Enum.any?(body["details"], &(&1["field"] == "cnpj"))
    end

    test "clinic_id no corpo é ignorado (whitelist; tenant vem do escopo)", %{
      base_conn: base_conn
    } do
      {owner, clinic} = owner_with_clinic()
      other = sign_in!(email_unico("user"))

      {:ok, other_clinic} =
        Accounts.onboard_clinic("Outra #{System.unique_integer([:positive])}", %{}, actor: other)

      body =
        base_conn
        |> authed(owner)
        |> patch(~p"/api/clinic", %{nome: "Renomeada", clinic_id: other_clinic.id})
        |> json_response(200)

      # editou a PRÓPRIA clínica, não a do corpo.
      assert body["clinic"]["id"] == clinic.id
      assert body["clinic"]["nome"] == "Renomeada"
    end

    test "recepção não edita (403)", %{base_conn: base_conn} do
      {owner, clinic} = owner_with_clinic()
      recep = sessao_de_membro!(owner, clinic, :recepcao)

      assert base_conn
             |> authed(recep)
             |> patch(~p"/api/clinic", %{nome: "Hack"})
             |> json_response(403)
    end

    test "profissional (sem gestão) não edita (403)", %{base_conn: base_conn} do
      {owner, clinic} = owner_with_clinic()
      prof = sessao_de_membro!(owner, clinic, :profissional)

      assert base_conn
             |> authed(prof)
             |> patch(~p"/api/clinic", %{nome: "Hack"})
             |> json_response(403)
    end

    test "endereço absurdamente longo devolve 422 (limite no servidor, não só no client)", %{
      base_conn: base_conn
    } do
      {owner, _clinic} = owner_with_clinic()

      body =
        base_conn
        |> authed(owner)
        |> patch(~p"/api/clinic", %{endereco: String.duplicate("a", 10_000)})
        |> json_response(422)

      assert body["error"] == "invalid"
      assert Enum.any?(body["details"], &(&1["field"] == "endereco"))
    end

    test "CNPJ absurdamente longo devolve 422 (normalize não fura o max_length)", %{
      base_conn: base_conn
    } do
      {owner, _clinic} = owner_with_clinic()

      body =
        base_conn
        |> authed(owner)
        |> patch(~p"/api/clinic", %{cnpj: String.duplicate("1", 10_000)})
        |> json_response(422)

      assert body["error"] == "invalid"
      assert Enum.any?(body["details"], &(&1["field"] == "cnpj"))
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> patch(~p"/api/clinic", %{nome: "X"}) |> json_response(401)
    end
  end
end
