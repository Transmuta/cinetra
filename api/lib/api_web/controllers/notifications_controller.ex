defmodule ApiWeb.NotificationsController do
  @moduledoc """
  A caixa de notificações in-app do usuário (doc 31). Molde dos demais controllers de tenant:
  `with_member_scope` na fronteira (o recorte por destinatário é da policy do recurso),
  `error_response/2` na escada de erros. `clinic_id` sempre do escopo (09 §8).

  A leitura é para qualquer membro (cada um só vê a própria caixa, garantido pela policy). Não há
  escrita de conteúdo pela UI — só "marcar lida" (uma ou todas).
  """
  use ApiWeb, :controller

  import ApiWeb.TenantScope

  alias Api.Notifications
  alias ApiWeb.NotificationsJSON

  # GET /api/notifications  — a caixa + o contador do badge.
  def index(conn, params) do
    with_member_scope(conn, fn scope ->
      only_unread = Api.Params.truthy?(params["unread"])
      notifications = Notifications.list_inbox(scope, only_unread: only_unread)

      # No caminho do badge (`?unread=1`, o que o layout do web chama em toda navegação) a lista
      # JÁ é a das não-lidas — contá-la é o `unread`, sem uma segunda query idêntica. Só a caixa
      # completa (default) precisa do `COUNT` à parte.
      unread = if only_unread, do: length(notifications), else: Notifications.unread_count(scope)

      json(conn, %{
        notifications: Enum.map(notifications, &NotificationsJSON.notification/1),
        unread: unread
      })
    end)
  end

  # POST /api/notifications/:id/read  — marca uma como lida.
  def mark_read(conn, %{"id" => id}) do
    with_member_scope(conn, fn scope ->
      case Notifications.mark_read(scope, id) do
        {:ok, notification} ->
          json(conn, %{notification: NotificationsJSON.notification(notification)})

        {:error, :not_found} ->
          not_found(conn)

        {:error, error} ->
          error_response(conn, error)
      end
    end)
  end

  # POST /api/notifications/read-all  — zera o badge.
  def mark_all_read(conn, _params) do
    with_member_scope(conn, fn scope ->
      count = Notifications.mark_all_read(scope)
      json(conn, %{marked: count, unread: 0})
    end)
  end
end
