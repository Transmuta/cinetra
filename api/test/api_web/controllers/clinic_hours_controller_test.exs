defmodule ApiWeb.ClinicHoursControllerTest do
  @moduledoc """
  Endpoints do horário semanal da clínica (doc 22 §3). Integração real: sessão + `LoadScope`,
  RBAC (leitura para todo membro, escrita só owner/admin) e a escada 401/403/422.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts

  defp email, do: "hours-#{System.unique_integer([:positive])}@example.com"

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

  setup %{conn: conn} do
    {owner, clinic} = owner_with_clinic()
    %{conn: authed(conn, owner), base_conn: conn, owner: owner, clinic: clinic}
  end

  describe "GET /api/clinic-hours" do
    test "devolve o expediente seedado como mapa dow→períodos", %{conn: conn} do
      body = conn |> get(~p"/api/clinic-hours") |> json_response(200)
      hours = body["clinic_hours"]

      assert map_size(hours) == 7
      assert hours["1"] == [["08:00", "12:00"], ["13:00", "18:00"]]
      assert hours["6"] == [["08:00", "12:00"]]
      assert hours["0"] == []
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn |> get(~p"/api/clinic-hours") |> json_response(401)
    end

    test "autenticado sem clínica ativa devolve 403", %{base_conn: base_conn} do
      orphan = sign_in(email())
      assert base_conn |> authed(orphan) |> get(~p"/api/clinic-hours") |> json_response(403)
    end

    test "qualquer membro lê (recepção, 200)", %{
      base_conn: base_conn,
      owner: owner,
      clinic: clinic
    } do
      recep = active_member_session(owner, clinic, :recepcao)
      body = base_conn |> authed(recep) |> get(~p"/api/clinic-hours") |> json_response(200)
      assert map_size(body["clinic_hours"]) == 7
    end

    test "não vaza o expediente de outra clínica", %{conn: conn} do
      other = sign_in(email())

      {:ok, other_clinic} =
        Accounts.onboard_clinic("Outra #{System.unique_integer([:positive])}", %{}, actor: other)

      # muda a outra clínica; a nossa continua no seed.
      Api.Scheduling.update_clinic_hours(scope(other, other_clinic), %{1 => [["06:00", "07:00"]]})

      body = conn |> get(~p"/api/clinic-hours") |> json_response(200)
      assert body["clinic_hours"]["1"] == [["08:00", "12:00"], ["13:00", "18:00"]]
    end
  end

  describe "PATCH /api/clinic-hours" do
    test "owner substitui os dias enviados (200)", %{conn: conn} do
      body =
        conn
        |> patch(~p"/api/clinic-hours", %{clinic_hours: %{"1" => [["09:00", "17:00"]], "0" => []}})
        |> json_response(200)

      assert body["clinic_hours"]["1"] == [["09:00", "17:00"]]
      # dia não enviado mantém o seed.
      assert body["clinic_hours"]["6"] == [["08:00", "12:00"]]
    end

    test "ignora chaves fora de 0..6 e o confirm (whitelist)", %{conn: conn} do
      body =
        conn
        |> patch(~p"/api/clinic-hours", %{
          clinic_hours: %{"9" => [["06:00", "07:00"]], "2" => [["10:00", "11:00"]]},
          confirm: true
        })
        |> json_response(200)

      assert body["clinic_hours"]["2"] == [["10:00", "11:00"]]
      refute Map.has_key?(body["clinic_hours"], "9")
    end

    test "períodos inválidos devolvem 422 sem aplicar nada", %{conn: conn} do
      body =
        conn
        |> patch(~p"/api/clinic-hours", %{
          clinic_hours: %{"1" => [["09:00", "17:00"]], "2" => [["18:00", "08:00"]]}
        })
        |> json_response(422)

      assert body["error"] == "invalid"
      # o dia 1 não foi tocado (validação da semana inteira antes de escrever).
      novo = conn |> get(~p"/api/clinic-hours") |> json_response(200)
      assert novo["clinic_hours"]["1"] == [["08:00", "12:00"], ["13:00", "18:00"]]
    end

    test "recepção não escreve (403)", %{base_conn: base_conn, owner: owner, clinic: clinic} do
      recep = active_member_session(owner, clinic, :recepcao)

      assert base_conn
             |> authed(recep)
             |> patch(~p"/api/clinic-hours", %{clinic_hours: %{"1" => [["09:00", "10:00"]]}})
             |> json_response(403)
    end

    test "sem sessão devolve 401", %{base_conn: base_conn} do
      assert base_conn
             |> patch(~p"/api/clinic-hours", %{clinic_hours: %{"1" => []}})
             |> json_response(401)
    end
  end

  defp scope(user, clinic) do
    membership = Accounts.get_active_membership!(user.id, clinic.id, authorize?: false)
    Api.Scope.with_membership(user, membership)
  end
end
