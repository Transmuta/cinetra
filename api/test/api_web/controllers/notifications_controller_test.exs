defmodule ApiWeb.NotificationsControllerTest do
  @moduledoc """
  Endpoints da caixa de notificações (doc 31). Integração real: sessão + `LoadScope`, a leitura
  recortada por destinatário (cada um só vê a própria), o contador do badge e o "marcar lida"
  (uma e todas). `clinic_id` sempre do escopo.
  """
  use ApiWeb.ConnCase, async: false

  alias Api.Accounts
  alias Api.Notifications

  defp email, do: "nc-#{System.unique_integer([:positive])}@example.com"

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

  defp as(user), do: authed(Phoenix.ConnTest.build_conn(), user)

  defp fixture do
    owner = sign_in(email())
    {:ok, clinic} = Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)
    %{owner: owner, clinic: clinic}
  end

  defp notify(clinic, recipient, attrs \\ %{}) do
    {:ok, n} =
      Notifications.create_notification(
        Map.merge(%{recipient_id: recipient.id, kind: :member_joined, title: "T", body: "B", data: %{}}, attrs),
        tenant: clinic.id,
        authorize?: false
      )

    n
  end

  describe "GET /api/notifications" do
    test "devolve a caixa do usuário e o contador de não-lidas" do
      ctx = fixture()
      notify(ctx.clinic, ctx.owner, %{title: "Primeira"})
      notify(ctx.clinic, ctx.owner, %{title: "Segunda"})

      body = as(ctx.owner) |> get("/api/notifications") |> json_response(200)

      assert body["unread"] == 2
      assert Enum.map(body["notifications"], & &1["title"]) == ["Segunda", "Primeira"]
      assert Enum.all?(body["notifications"], &(&1["read"] == false))
    end

    test "sem sessão responde 401" do
      assert Phoenix.ConnTest.build_conn() |> get("/api/notifications") |> json_response(401)
    end

    test "?unread=1 traz só as não-lidas" do
      ctx = fixture()
      lida = notify(ctx.clinic, ctx.owner)
      notify(ctx.clinic, ctx.owner, %{title: "Nova"})
      {:ok, _} = Notifications.mark_read(scope(ctx), lida.id)

      body = as(ctx.owner) |> get("/api/notifications?unread=1") |> json_response(200)
      assert length(body["notifications"]) == 1
    end
  end

  describe "POST /api/notifications/:id/read" do
    test "marca uma como lida" do
      ctx = fixture()
      n = notify(ctx.clinic, ctx.owner)

      body = as(ctx.owner) |> post("/api/notifications/#{n.id}/read") |> json_response(200)
      assert body["notification"]["read"] == true
    end

    test "id inexistente/de outro dono responde 404" do
      ctx = fixture()
      assert as(ctx.owner) |> post("/api/notifications/#{Ecto.UUID.generate()}/read") |> json_response(404)
    end
  end

  describe "POST /api/notifications/read-all" do
    test "zera o badge e devolve quantas marcou" do
      ctx = fixture()
      notify(ctx.clinic, ctx.owner)
      notify(ctx.clinic, ctx.owner)

      body = as(ctx.owner) |> post("/api/notifications/read-all") |> json_response(200)
      assert body["marked"] == 2
      assert body["unread"] == 0

      assert as(ctx.owner) |> get("/api/notifications") |> json_response(200) |> Map.get("unread") == 0
    end
  end

  defp scope(ctx) do
    {:ok, membership} = Accounts.get_active_membership(ctx.owner.id, ctx.clinic.id, authorize?: false)
    Api.Scope.with_membership(ctx.owner, membership)
  end
end
