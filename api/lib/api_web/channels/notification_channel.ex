defmodule ApiWeb.NotificationChannel do
  @moduledoc """
  O canal da caixa de notificações de um usuário (doc 31 §5). Tópico de wire:

      notifications:<clinic_id>

  O cliente assina só pela clínica; o canal escuta o tópico **por-usuário**
  (`Api.Notifications.Feed.user_topic/2`, que inclui o `user_id` do socket) — assim a caixa de um
  membro não vaza para o socket de outro, mesmo os dois na mesma clínica.

  As guardas do `join` são as dos outros dois canais, e por isso moram em `ApiWeb.ChannelScope`:
  confere o `clinic_id` do tópico contra o do token e relê o vínculo ativo (o token vive 15 min;
  um acesso revogado nesse intervalo ainda traz token válido). O push é um sinal leve "chegou
  notificação" — o cliente incrementa o badge e, se a tela estiver aberta, recarrega a lista pelo
  `GET /api/notifications` (onde mora a serialização).
  """
  use Phoenix.Channel

  alias Api.Notifications.Feed
  alias ApiWeb.ChannelScope

  @impl true
  def join(topic, _params, socket) do
    with {:ok, clinic_id} <- ChannelScope.parse_topic(topic, "notifications:"),
         {:ok, _scope} <- ChannelScope.authorize(clinic_id, socket) do
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
end
