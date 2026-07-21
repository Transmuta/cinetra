defmodule ApiWeb.NotificationChannel do
  @moduledoc """
  O canal da caixa de notificações de um usuário (doc 31 §5). Tópico de wire:

      notifications:<clinic_id>

  O cliente assina só pela clínica; o canal escuta o tópico **por-usuário**
  (`Api.Notifications.Feed.user_topic/2`, que inclui o `user_id` do socket) — assim a caixa de um
  membro não vaza para o socket de outro, mesmo os dois na mesma clínica.

  As guardas do `join` são as do `WaitlistChannel`: confere o `clinic_id` do tópico contra o do
  token e relê o vínculo ativo (o token vive 15 min; um acesso revogado nesse intervalo ainda traz
  token válido). O push é um sinal leve "chegou notificação" — o cliente incrementa o badge e, se a
  tela estiver aberta, recarrega a lista pelo `GET /api/notifications` (onde mora a serialização).
  """
  use Phoenix.Channel

  alias Api.Notifications.Feed

  @impl true
  def join(topic, _params, socket) do
    with {:ok, clinic_id} <- parse_topic(topic),
         :ok <- same_clinic(clinic_id, socket),
         :ok <- active_member?(socket.assigns.user_id, clinic_id) do
      Feed.subscribe(Feed.user_topic(clinic_id, socket.assigns.user_id))
      {:ok, socket}
    else
      :invalid_topic -> {:error, %{reason: "invalid_topic"}}
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:notification, notification}, socket) do
    push(socket, "notification_created", ApiWeb.NotificationsJSON.summary(notification))
    {:noreply, socket}
  end

  defp parse_topic("notifications:" <> clinic_id) when clinic_id != "", do: {:ok, clinic_id}
  defp parse_topic(_topic), do: :invalid_topic

  defp same_clinic(clinic_id, %{assigns: %{clinic_id: clinic_id}}), do: :ok
  defp same_clinic(_clinic_id, _socket), do: :error

  defp active_member?(user_id, clinic_id) do
    case Api.Accounts.get_active_membership(user_id, clinic_id, authorize?: false) do
      {:ok, %{}} -> :ok
      _ -> :error
    end
  end
end
