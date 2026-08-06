defmodule ApiWeb.AuthStrategyController do
  @moduledoc """
  Recebe o resultado do hand-off OAuth (Google, ADR-015) do `AshAuthentication.Phoenix`.
  As rotas `/api/auth/strategy/...` (montadas por `auth_routes` no router) despacham para
  a estratégia via Assent e chamam `success/4` ou `failure/3` aqui. No sucesso, assina a
  sessão e redireciona ao app web; na falha, redireciona ao login com erro.
  """
  use ApiWeb, :controller
  use AshAuthentication.Phoenix.Controller

  alias AshAuthentication.Plug.Helpers

  @impl true
  def success(conn, _activity, user, _token) do
    # Primeiro acesso do convidado (por Google) ativa seus vínculos pendentes (D24).
    _ = Api.Accounts.Invites.activate_pending(user)

    conn
    |> Helpers.store_in_session(user)
    |> redirect(external: Api.web_app_url())
  end

  # **401 de verdade, sem `Location`** (doc 96, H-10) — o irmão do `magic_link_callback`, e o
  # mesmo raciocínio: `redirect/2` com `put_status(:unauthorized)` antes emite 401 **com** header
  # `Location`, um redirect que browser nenhum segue. Quem lê é o BFF, com `redirect: 'manual'`,
  # e ele decide o destino sozinho (`redirect(303, '/entrar?erro=google')`).
  @impl true
  def failure(conn, _activity, _reason) do
    ApiWeb.TenantScope.unauthorized(conn)
  end

  @impl true
  def sign_out(conn, _params) do
    conn
    |> clear_session(:api)
    |> redirect(external: Api.web_app_url())
  end
end
