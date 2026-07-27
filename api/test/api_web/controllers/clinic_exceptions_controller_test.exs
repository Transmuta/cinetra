defmodule ApiWeb.ClinicExceptionsControllerTest do
  @moduledoc """
  Endpoints das exceções de data da clínica (doc 22 §3). Integração real: sessão + `LoadScope`,
  RBAC e a escada 401/403/404/422.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Scheduling

  defp owner_with_clinic do
    owner = sign_in!(email_unico("exc"))

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    {owner, clinic}
  end

  defp scope(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end

  defp fechado(overrides \\ %{}),
    do: Map.merge(%{data: ~D[2026-07-09], tipo: :fechado}, overrides)

  setup %{conn: conn} do
    {owner, clinic} = owner_with_clinic()
    %{conn: authed(conn, owner), base_conn: conn, owner: owner, clinic: clinic}
  end

  describe "GET /api/clinic-exceptions" do
    test "lista vazia quando não há exceções", %{conn: conn} do
      body = conn |> get(~p"/api/clinic-exceptions") |> json_response(200)
      assert body["clinic_exceptions"] == []
    end

    test "lista as da clínica ordenadas por data", %{conn: conn, owner: owner, clinic: clinic} do
      Scheduling.create_clinic_exception(scope(owner, clinic), fechado(%{data: ~D[2026-07-24]}))
      Scheduling.create_clinic_exception(scope(owner, clinic), fechado(%{data: ~D[2026-07-09]}))

      body = conn |> get(~p"/api/clinic-exceptions") |> json_response(200)

      assert Enum.map(body["clinic_exceptions"], & &1["data"]) == ["2026-07-09", "2026-07-24"]
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> get(~p"/api/clinic-exceptions") |> json_response(401)
    end

    test "qualquer membro lê (recepção, 200)", %{
      base_conn: base_conn,
      owner: owner,
      clinic: clinic
    } do
      recep = sessao_de_membro!(owner, clinic, :recepcao)
      body = base_conn |> authed(recep) |> get(~p"/api/clinic-exceptions") |> json_response(200)
      assert body["clinic_exceptions"] == []
    end
  end

  describe "POST /api/clinic-exceptions" do
    test "cria dia fechado (201)", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/clinic-exceptions", %{
          data: "2026-07-09",
          nome: "Feriado",
          tipo: "fechado"
        })
        |> json_response(201)

      assert %{"data" => "2026-07-09", "nome" => "Feriado", "tipo" => "fechado", "periods" => []} =
               body["clinic_exception"]

      assert is_binary(body["clinic_exception"]["id"])
    end

    test "cria horário especial com períodos (201)", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/clinic-exceptions", %{
          data: "2026-07-24",
          nome: "Reduzido",
          tipo: "horario",
          periods: [["08:00", "12:00"]]
        })
        |> json_response(201)

      assert body["clinic_exception"]["tipo"] == "horario"
      assert body["clinic_exception"]["periods"] == [["08:00", "12:00"]]
    end

    test "o objeto não vaza clinic_id/professional_id/timestamps", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/clinic-exceptions", %{data: "2026-07-09", tipo: "fechado"})
        |> json_response(201)

      assert Enum.sort(Map.keys(body["clinic_exception"])) == ~w(data id nome periods tipo)
    end

    test "IGNORA professional_id do corpo — a rota é da clínica", %{conn: conn, clinic: clinic} do
      body =
        conn
        |> post(~p"/api/clinic-exceptions", %{
          data: "2026-07-09",
          tipo: "fechado",
          professional_id: Ecto.UUID.generate()
        })
        |> json_response(201)

      # nasceu como exceção da clínica (aparece na listagem, que filtra professional_id nulo).
      _ = clinic
      listadas = conn |> get(~p"/api/clinic-exceptions") |> json_response(200)

      assert Enum.any?(
               listadas["clinic_exceptions"],
               &(&1["id"] == body["clinic_exception"]["id"])
             )
    end

    test "data duplicada devolve 422 (H3)", %{conn: conn} do
      conn |> post(~p"/api/clinic-exceptions", %{data: "2026-12-25", tipo: "fechado"})

      body =
        conn
        |> post(~p"/api/clinic-exceptions", %{data: "2026-12-25", tipo: "fechado", nome: "Outra"})
        |> json_response(422)

      assert body["error"] == "invalid"
    end

    test "horário sem períodos devolve 422", %{conn: conn} do
      assert conn
             |> post(~p"/api/clinic-exceptions", %{data: "2026-07-24", tipo: "horario"})
             |> json_response(422)
    end

    test "recepção não cria (403)", %{base_conn: base_conn, owner: owner, clinic: clinic} do
      recep = sessao_de_membro!(owner, clinic, :recepcao)

      assert base_conn
             |> authed(recep)
             |> post(~p"/api/clinic-exceptions", %{data: "2026-07-09", tipo: "fechado"})
             |> json_response(403)
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn
             |> post(~p"/api/clinic-exceptions", %{data: "2026-07-09", tipo: "fechado"})
             |> json_response(401)
    end
  end

  describe "DELETE /api/clinic-exceptions/:id" do
    test "apaga e devolve 204", %{conn: conn, owner: owner, clinic: clinic} do
      {:ok, exc} = Scheduling.create_clinic_exception(scope(owner, clinic), fechado())

      assert conn |> delete(~p"/api/clinic-exceptions/#{exc.id}") |> response(204)

      assert conn
             |> get(~p"/api/clinic-exceptions")
             |> json_response(200)
             |> Map.get("clinic_exceptions") == []
    end

    test "id inexistente devolve 404", %{conn: conn} do
      assert conn
             |> delete(~p"/api/clinic-exceptions/#{Ecto.UUID.generate()}")
             |> json_response(404)
    end

    test "exceção de outra clínica devolve 404 (isolamento)", %{conn: conn} do
      other = sign_in!(email_unico("exc"))

      {:ok, other_clinic} =
        Accounts.onboard_clinic("Outra #{System.unique_integer([:positive])}", %{}, actor: other)

      {:ok, alheia} = Scheduling.create_clinic_exception(scope(other, other_clinic), fechado())

      assert conn |> delete(~p"/api/clinic-exceptions/#{alheia.id}") |> json_response(404)
    end

    test "recepção não apaga (403)", %{base_conn: base_conn, owner: owner, clinic: clinic} do
      {:ok, exc} = Scheduling.create_clinic_exception(scope(owner, clinic), fechado())
      recep = sessao_de_membro!(owner, clinic, :recepcao)

      assert base_conn
             |> authed(recep)
             |> delete(~p"/api/clinic-exceptions/#{exc.id}")
             |> json_response(403)
    end
  end
end
