defmodule ApiWeb.RateLimit do
  @moduledoc """
  O que os dois limitadores de fronteira (`ApiWeb.Plugs.RateLimitAuth` e
  `ApiWeb.Plugs.RateLimitGlobal`) têm em comum: como se identifica o cliente, como se recusa, e
  quando a enforcement está ligada.

  Os plugs ficam só com o que de fato difere entre eles — a política de chave, a janela e o
  limite. Antes desta extração cada um tinha o seu `deny`, e os dois **já haviam divergido**: um
  mandava `retry-after` e o outro não, de modo que um cliente educado ficava sem orientação justo
  no endpoint mais sensível (bate-volta doc 68, causa F).
  """

  import Plug.Conn

  @doc """
  Identidade do cliente para fins de limite: o **ator** quando a requisição já chegou autenticada,
  o **IP** quando não.

  Duas pessoas atrás do mesmo NAT dividem o balde enquanto estão deslogadas e passam a ter baldes
  próprios depois de entrar — que é o comportamento desejado, porque só aí existe alguém a quem
  atribuir o consumo.
  """
  @spec client_key(Plug.Conn.t()) :: String.t()
  def client_key(%Plug.Conn{assigns: %{scope: %Api.Scope{user: %{id: id}}}}) when is_binary(id),
    do: "actor:" <> id

  def client_key(conn), do: "ip:" <> ApiWeb.ClientIp.get(conn)

  @doc """
  Recusa a requisição com **429** e diz **quando voltar**.

  `retry_after_ms` é o que o Hammer devolve no `{:deny, _}` — em milissegundos. O header
  `Retry-After` é definido em **segundos** (RFC 7231 §7.1.3); mandar o valor cru diria ao cliente
  para esperar horas.
  """
  @spec deny(Plug.Conn.t(), non_neg_integer()) :: Plug.Conn.t()
  def deny(conn, retry_after_ms) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(max(1, ceil(retry_after_ms / 1000))))
    |> put_resp_content_type("application/json")
    |> send_resp(429, ~s({"error":"rate_limited"}))
    |> halt()
  end

  @doc """
  A enforcement está ligada? Só em produção (`config :api, rate_limit_enabled: true`).

  Em dev/test os plugs são no-op para não atrapalhar os fluxos locais; as tabelas ETS existem em
  todos os ambientes de propósito, para o teste poder exercitar o caminho real.

  `which` permite desligar **um** limitador sem derrubar o outro. A chave única era uma armadilha
  disfarçada de DRY: é o mesmo mecanismo, mas não é a mesma decisão. Num incidente em que o teto
  global esteja barrando tráfego legítimo, quem apaga a flag para restabelecer o serviço não pode
  estar apagando junto o anti-brute-force do magic link (bate-volta doc 68, causa F).

      config :api, rate_limit_global_enabled: false   # só o global cai; auth segue protegido
  """
  @spec enabled?(:auth | :global) :: boolean()
  def enabled?(which \\ :auth)

  def enabled?(:global) do
    enabled?(:auth) and Application.get_env(:api, :rate_limit_global_enabled, true)
  end

  def enabled?(:auth), do: Application.get_env(:api, :rate_limit_enabled, false)
end
