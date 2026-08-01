defmodule ApiWeb.Plugs.RateLimitGlobal do
  @moduledoc """
  Rate limit do tráfego geral — todo endpoint que não tem limite personalizado. Ficam de fora os
  endpoints de auth (que têm o `RateLimitAuth` próprio, com chaves por e-mail/ator mais
  apertadas), os health checks (liveness só pode depender do BEAM, doc 62 §7.1) e os webhooks dos
  providers (a rajada legítima de uma campanha estouraria o balde do IP do provider; a guarda
  deles é a assinatura).

  ## Dois estágios, e por que não um

  O plug roda **duas vezes**, com papéis diferentes e em lugares diferentes da pilha:

    * `stage: :edge` — plug do **endpoint**, entre `Plug.Telemetry` e `Plug.Parsers`. Chave por
      **IP**, teto folgado (2.000/min). Corta enxurrada anônima antes de qualquer trabalho.
    * `stage: :actor` — plug de **pipeline do router**, depois do `LoadScope`. Chave por **ator**
      (ou IP, se anônimo), teto de 200/min. É o limite fino, o que a fatia prometeu.

  ### Por que a borda é plug de ENDPOINT (doc 96, L-2)

  Ela já foi pipeline do router, e nessa posição cumpria metade do que prometia: cortava antes do
  **banco** (o `LoadScope` vem depois), mas não antes do **corpo** — `Plug.Parsers` é plug do
  endpoint e roda antes do router, então uma requisição que ia levar 429 já tinha lido, alocado e
  decodificado até 8 MB. Num servidor de 2 vCPU sem nada na frente, isso é a diferença entre
  "cortamos a enxurrada" e "cortamos a enxurrada depois de pagar por ela".

  Subir o plug para o endpoint também lhe dá a cobertura que o router não tinha: `/webhooks` e os
  health checks nunca passavam pelo estágio de borda, porque cada scope escolhia seus pipelines.
  Agora eles passam **por opção explícita** — ver `@sem_teto_de_borda` abaixo.

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

  # As isenções do estágio de borda, agora que ele é plug de endpoint e alcança **tudo**.
  #
  # Cada uma tem a razão que o `router.ex` já registrava, e nenhuma é conveniência:
  #
  #   * `/webhooks` — a rajada legítima de uma campanha estouraria o balde do IP do provider, e a
  #     guarda dessa rota é a assinatura, não o teto (o corpo dela tem teto próprio, no
  #     `CacheRawBody`, que é o que L-1 fechou);
  #   * `/api/health` e `/api/ready` — liveness não pode depender do rate limiter (doc 62 §7.1).
  #     Um orquestrador que recebe 429 no health check reinicia uma instância que está viva.
  #
  # Os endpoints de auth **não** estão aqui: eles são isentos do estágio de ATOR (têm o
  # `RateLimitAuth`, mais apertado), não do teto de infraestrutura da borda.
  @sem_teto_de_borda ["/webhooks", "/api/health", "/api/ready"]

  @impl true
  def init(opts), do: Keyword.get(opts, :stage, :actor)

  @impl true
  def call(conn, stage) do
    if RateLimit.enabled?(:global) and not isento?(conn, stage) do
      case RateLimiter.Global.hit(key(conn, stage), scale(), limit(stage)) do
        {:allow, _count} -> conn
        {:deny, retry_after_ms} -> RateLimit.deny(conn, retry_after_ms)
      end
    else
      conn
    end
  end

  # Só a borda tem isenção por caminho: o estágio de ator continua sendo escolhido pipeline a
  # pipeline no router, que é onde ele sempre esteve.
  defp isento?(conn, :edge),
    do: Enum.any?(@sem_teto_de_borda, &String.starts_with?(conn.request_path, &1))

  defp isento?(_conn, :actor), do: false

  # Na borda o escopo ainda não existe (o plug roda antes do `LoadScope`), então a chave é sempre
  # o IP. Prefixos distintos mantêm os dois estágios em baldes separados.
  defp key(conn, :edge), do: "edge:ip:" <> ClientIp.get(conn)
  defp key(conn, :actor), do: "global:" <> RateLimit.client_key(conn)

  defp limit(:edge), do: Keyword.get(config(), :edge_limit, @edge_limit)
  defp limit(:actor), do: Keyword.get(config(), :limit, @limit)

  defp scale, do: Keyword.get(config(), :scale, @scale)
  defp config, do: Application.get_env(:api, :rate_limit_global, [])
end
