defmodule Api.Notifications.Feed do
  @moduledoc """
  O barramento em tempo real da caixa de um usuário — o que faz o badge do sino subir sem refresh
  (doc 31 §5). Mesma mecânica dos canais de agenda/fila (`Phoenix.PubSub`), com um escopo novo: um
  tópico por **(clínica, usuário)**, porque a notificação é por-tenant e destinada a uma pessoa.

  Fonte única do nome do tópico: o `Api.Notifications.Fanout` publica e o
  `ApiWeb.NotificationChannel` assina pelo mesmo caminho.
  """

  @doc "Tópico da caixa de um usuário numa clínica."
  def user_topic(clinic_id, user_id) when is_binary(clinic_id) and is_binary(user_id),
    do: "notifications:#{clinic_id}:#{user_id}"

  @doc "Assina o tópico (o canal chama no `join`)."
  def subscribe(topic) when is_binary(topic), do: Phoenix.PubSub.subscribe(Api.PubSub, topic)

  @doc "Publica a chegada de uma notificação para o dono (o canal repassa ao cliente)."
  def broadcast_new(%Api.Notifications.Notification{} = notification) do
    topic = user_topic(notification.clinic_id, notification.recipient_id)
    Phoenix.PubSub.broadcast(Api.PubSub, topic, {:notification, notification})
  end
end
