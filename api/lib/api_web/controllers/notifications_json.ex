defmodule ApiWeb.NotificationsJSON do
  @moduledoc """
  Serialização da caixa de notificações (doc 31). `read` é o booleano derivado de `read_at` (a UI
  não precisa do instante, só do estado); `data` viaja como está (o mínimo para navegar).
  """

  @doc "Uma notificação para a lista da tela."
  def notification(n) do
    %{
      id: n.id,
      kind: n.kind,
      title: n.title,
      body: n.body,
      data: n.data,
      read: not is_nil(n.read_at),
      inserted_at: n.inserted_at
    }
  end

  @doc "O resumo leve empurrado pelo canal quando uma notificação chega (o cliente sobe o badge)."
  def summary(n) do
    %{id: n.id, kind: n.kind, title: n.title}
  end
end
