defmodule ApiWeb.NotificationChannelTest do
  @moduledoc """
  O canal da caixa de um usuário (doc 31 §5). Protege, em ordem de gravidade:

    * **o `clinic_id` do tópico é validado no `join`** — o WebSocket não passa pela sessão nem
      pela RLS;
    * o vínculo revogado depois do token emitido não entra;
    * uma notificação para o usuário empurra `notification_created`, e a caixa de um membro **não**
      vaza para o socket de outro na mesma clínica (o tópico interno é por-usuário).
  """
  use ApiWeb.ChannelCase, async: false

  alias Api.Accounts
  alias Api.Notifications

  defp email, do: "nchan-#{System.unique_integer([:positive])}@example.com"

  defp sign_in(addr) do
    :ok = Accounts.request_magic_link(addr, %{register?: true})
    assert_receive {:email, mail}, 1_000
    [_, token] = Regex.run(~r/token=([\w.\-]+)/, mail.text_body)
    {:ok, user} = Accounts.sign_in_with_magic_link(token)
    user
  end

  defp member(owner, clinic, papel) do
    addr = email()

    {:ok, pending} =
      Accounts.invite_member_by_email(addr, %{papel: papel, clinic_id: clinic.id}, actor: owner)

    user = Accounts.get_user_by_email!(addr, authorize?: false)
    {:ok, membership} = Accounts.accept_invite(pending, actor: user)
    {sign_in(addr), membership}
  end

  defp fixture do
    owner = sign_in(email())

    {:ok, clinic} =
      Accounts.onboard_clinic("Clínica #{System.unique_integer([:positive])}", %{}, actor: owner)

    %{owner: owner, clinic: clinic}
  end

  defp socket_for(user, clinic) do
    Phoenix.ChannelTest.socket(ApiWeb.UserSocket, "user_socket:#{user.id}", %{
      user_id: user.id,
      clinic_id: clinic.id
    })
  end

  defp topic(clinic), do: "notifications:#{clinic.id}"

  defp notify(clinic, recipient) do
    {:ok, n} =
      Notifications.create_notification(
        %{recipient_id: recipient.id, kind: :member_joined, title: "Oi", body: "B", data: %{}},
        tenant: clinic.id,
        authorize?: false
      )

    n
  end

  describe "join" do
    test "membro entra no tópico da própria clínica" do
      ctx = fixture()

      assert {:ok, _reply, _socket} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.NotificationChannel, topic(ctx.clinic))
    end

    test "tópico de OUTRA clínica é recusado" do
      ctx = fixture()
      intruso = fixture()

      assert {:error, %{reason: "unauthorized"}} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.NotificationChannel, topic(intruso.clinic))
    end

    test "tópico malformado é recusado" do
      ctx = fixture()

      assert {:error, %{reason: "invalid_topic"}} =
               ctx.owner
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.NotificationChannel, "notifications:")
    end

    test "vínculo revogado depois do token emitido não entra" do
      ctx = fixture()
      {user, membership} = member(ctx.owner, ctx.clinic, :recepcao)
      :ok = Accounts.revoke_access(membership, actor: ctx.owner)

      assert {:error, %{reason: "unauthorized"}} =
               user
               |> socket_for(ctx.clinic)
               |> subscribe_and_join(ApiWeb.NotificationChannel, topic(ctx.clinic))
    end
  end

  describe "sinal" do
    test "uma notificação para o usuário empurra notification_created" do
      ctx = fixture()

      {:ok, _, _socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.NotificationChannel, topic(ctx.clinic))

      Api.Notifications.Feed.broadcast_new(notify(ctx.clinic, ctx.owner))

      assert_push "notification_created", payload
      assert payload.title == "Oi"
    end

    test "a caixa de outro membro não vaza para este socket" do
      ctx = fixture()
      {outro, _m} = member(ctx.owner, ctx.clinic, :recepcao)

      {:ok, _, _socket} =
        ctx.owner
        |> socket_for(ctx.clinic)
        |> subscribe_and_join(ApiWeb.NotificationChannel, topic(ctx.clinic))

      Api.Notifications.Feed.broadcast_new(notify(ctx.clinic, outro))

      refute_push "notification_created", _payload
    end
  end
end
