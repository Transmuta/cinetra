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

  # GET /api/notifications  — a caixa paginada (`?limit=`, `?offset=`) + o contador do badge.
  def index(conn, params) do
    with_member_scope(conn, fn scope ->
      only_unread = Api.Params.truthy?(params["unread"])

      page =
        Notifications.list_inbox(scope,
          only_unread: only_unread,
          limit: parse_int(params["limit"]),
          offset: parse_int(params["offset"])
        )

      # Paginada (#54), a lista não responde mais "quantas não-lidas" — contar o que chegou
      # contaria só a página. O número vem sempre do `COUNT` no índice parcial, inclusive no
      # caminho do badge: é uma query a mais e ainda assim mais barata que pedir o total da
      # página (`count: true` lê o recorte inteiro — ver `Api.Pagination.page_opts/1`).
      unread = Notifications.unread_count(scope)

      json(conn, %{
        notifications: Enum.map(page.results, &NotificationsJSON.notification/1),
        unread: unread,
        page: page_json(page)
      })
    end)
  end

  # GET /api/notifications/unread-count  — só o número do badge.
  #
  # Existe porque o caminho do badge roda no load do layout, ou seja, em TODA navegação, e não
  # precisa de lista nenhuma. Pedindo pelo `index` ele custava duas queries — uma lista de uma
  # linha, que o BFF descartava, mais o `COUNT`. Aqui é uma, e vai ao índice parcial.
  def unread_count(conn, _params) do
    with_member_scope(conn, fn scope ->
      json(conn, %{unread: Notifications.unread_count(scope)})
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

  # DELETE /api/notifications  — esvazia a caixa (lidas e não-lidas).
  #
  # `DELETE` na coleção, e não um `POST /clear-all` ao lado do `read-all`: aqui a coleção INTEIRA
  # do dono deixa de existir, que é exatamente o que o verbo diz. O `read-all` é POST porque
  # "marcar lida" é uma transição de estado, não uma remoção.
  def clear_all(conn, _params) do
    with_member_scope(conn, fn scope ->
      count = Notifications.clear_all(scope)
      json(conn, %{cleared: count, unread: 0})
    end)
  end
end
