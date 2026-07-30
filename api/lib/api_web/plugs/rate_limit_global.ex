defmodule ApiWeb.Plugs.RateLimitGlobal do
  @moduledoc """
  Rate limit do tráfego geral — todo endpoint que não tem limite personalizado. Ficam de fora os
  endpoints de auth (que têm o `RateLimitAuth` próprio, com chaves por e-mail/ator mais
  apertadas), os health checks (liveness só pode depender do BEAM, doc 62 §7.1) e os webhooks dos
  providers (a rajada legítima de uma campanha estouraria o balde do IP do provider; a guarda
  deles é a assinatura).

  ## Dois estágios, e por que não um

  O plug roda **duas vezes** em cada scope, com papéis diferentes:

    * `stage: :edge` — **antes** do pipeline de sessão, chave por **IP**, teto folgado (2.000/min).
      Corta enxurrada anônima antes de qualquer trabalho.
    * `stage: :actor` — **depois** do `LoadScope`, chave por **ator** (ou IP, se anônimo), teto de
      200/min. É o limite fino, o que a fatia prometeu.

  O teto da borda **não** é "o limite, um pouco maior": é de outra natureza, e por isso é uma
  ordem de grandeza acima. Ele conta por **IP**, e uma clínica inteira sai por um IP só — dez
  pessoas na recepção, cada uma com direito aos seus 200/min, somam 2.000. Um teto de borda perto
  do teto por ator transformaria "o consultório está movimentado" em 429 para todo mundo. Quem
  limita pessoa é o estágio de ator; a borda existe só para que uma enxurrada não chegue ao banco.

  Um estágio só não resolve, e a razão é medida. A chave por ator exige o `LoadScope`, que exige a
  stack de sessão; enquanto o limite morava só depois dela, **cada requisição barrada ainda pagava
  5 queries** (sessão, token, membership). Um ator mandando 10 mil req/min gerava 49 mil queries
  descartadas — 42× o que "200 req/min" dá a entender, e 27 s de banco por minuto jogados fora
  (bate-volta doc 68, causa C). O estágio de borda corta isso antes do banco; o de ator mantém a
  precisão de quem consumiu o quê.

  O repo já havia chegado à mesma conclusão do outro lado da fronteira: *"rate limit primeiro,
  antes de qualquer outra checagem: ele é a guarda que também protege as guardas"*
  (`web/src/routes/api/client-error/+server.ts`).

  **Só bloqueia em produção** (`config :api, :rate_limit_enabled`). Limite e janela aceitam
  override por `config :api, :rate_limit_global` (`limit:`/`edge_limit:`/`scale:`, `scale` em ms)
  — é o que os testes usam para exercitar o pipeline sem centenas de requisições.
  """
  @behaviour Plug

  alias Api.RateLimiter
  alias ApiWeb.ClientIp
  alias ApiWeb.RateLimit

  @limit 200
  # 10 atores × o teto de cada um: o que cabe atrás de um NAT de recepção sem virar 429.
  @edge_limit 2_000
  @scale :timer.minutes(1)

  @impl true
  def init(opts), do: Keyword.get(opts, :stage, :actor)

  @impl true
  def call(conn, stage) do
    if RateLimit.enabled?(:global) do
      case RateLimiter.Global.hit(key(conn, stage), scale(), limit(stage)) do
        {:allow, _count} -> conn
        {:deny, retry_after_ms} -> RateLimit.deny(conn, retry_after_ms)
      end
    else
      conn
    end
  end

  # Na borda o escopo ainda não existe (o plug roda antes do `LoadScope`), então a chave é sempre
  # o IP. Prefixos distintos mantêm os dois estágios em baldes separados.
  defp key(conn, :edge), do: "edge:ip:" <> ClientIp.get(conn)
  defp key(conn, :actor), do: "global:" <> RateLimit.client_key(conn)

  defp limit(:edge), do: Keyword.get(config(), :edge_limit, @edge_limit)
  defp limit(:actor), do: Keyword.get(config(), :limit, @limit)

  defp scale, do: Keyword.get(config(), :scale, @scale)
  defp config, do: Application.get_env(:api, :rate_limit_global, [])
end
