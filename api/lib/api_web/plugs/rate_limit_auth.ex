defmodule ApiWeb.Plugs.RateLimitAuth do
  @moduledoc """
  Rate limiting dos endpoints de autenticação (auditoria doc 13, causa A). Janela deslizante
  via `Api.RateLimiter`. **Só bloqueia em produção** (`config :api, rate_limit_enabled`); em
  dev/test é no-op, para não atrapalhar os fluxos locais.

  Chaves por rota (deny se **qualquer uma** estourar):

    * `/api/auth/magic-link` — por **e-mail** (limita bombardear a caixa de um alvo) **e** por
      **IP** (limita um atacante disparando links para mil e-mails diferentes). Os dois juntos
      fecham o vetor de spam-relay que a sonda pegou.
    * demais (`/auth/google`, `/auth/switch-tenant`) — por **actor** quando autenticado, senão
      por IP.

  > Nota de produção: atrás de proxy, `conn.remote_ip` é o IP do proxy — quem resolve o IP real
  > do cliente é o `ApiWeb.ClientIp`, pela cadeia de headers confiáveis que ele documenta. A chave
  > por e-mail/ator já é robusta ao proxy por construção.
  """
  @behaviour Plug

  alias Api.RateLimiter
  alias ApiWeb.ClientIp
  alias ApiWeb.RateLimit

  # Janelas e limites. ATENÇÃO: o Hammer quer `scale` em **milissegundos** (`hit(key, scale_ms,
  # limite)`), não em segundos — passar 60 daria uma janela de 60ms (bug que só a app viva pegou;
  # o teste in-process passava por caber nos 60ms). `:timer.minutes/1` = minutos em ms.
  #   e-mail: 5 pedidos / 15 min (bombardear um alvo)
  #   IP:     10 pedidos / 2 min  (um IP disparando para vários e-mails)
  @email_scale :timer.minutes(15)
  @email_limit 5
  @ip_scale :timer.minutes(2)
  @ip_limit 10

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if RateLimit.enabled?() do
      enforce(conn, keys_for(conn))
    else
      conn
    end
  end

  defp enforce(conn, []), do: conn

  defp enforce(conn, [{key, scale, limit} | rest]) do
    case RateLimiter.hit(key, scale, limit) do
      {:allow, _count} -> enforce(conn, rest)
      {:deny, retry_after_ms} -> RateLimit.deny(conn, retry_after_ms)
    end
  end

  # Monta a lista de chaves {key, scale_ms, limite} conforme a rota.
  defp keys_for(%Plug.Conn{request_path: "/api/auth/magic-link"} = conn) do
    ip = ClientIp.get(conn)

    case magic_link_email(conn) do
      nil ->
        [{"ml:ip:" <> ip, @ip_scale, @ip_limit}]

      email ->
        [
          {"ml:email:" <> email, @email_scale, @email_limit},
          {"ml:ip:" <> ip, @ip_scale, @ip_limit}
        ]
    end
  end

  defp keys_for(conn) do
    id = RateLimit.client_key(conn)
    [{"auth:" <> conn.request_path <> ":" <> id, @ip_scale, @ip_limit}]
  end

  defp magic_link_email(conn) do
    (conn.body_params["email"] || get_in(conn.body_params, ["user", "email"]))
    |> normalize_email()
  end

  defp normalize_email(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_email(_), do: nil
end
