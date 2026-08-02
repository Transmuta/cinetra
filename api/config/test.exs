import Config

config :api, token_signing_secret: "ZF5ezrg8Ok6/UlQajfAaSey6CAGa15cn"
config :bcrypt_elixir, log_rounds: 1

config :api, Api.Repo,
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  database: "cinetra_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Oban em modo manual no teste: sem cron e sem filas rodando. O worker de limpeza é exercido
# chamando `perform/1` direto (o cron é config, não lógica).
config :api, Oban, testing: :manual

# Storage em memória (`test/support/storage_memory.ex`): a suíte de anexos não fala com o
# Cloudflare. As credenciais são falsas mas PRESENTES de propósito — `Api.Storage.configured?/0`
# precisa dar `true`, senão todo teste de anexo bateria no 503 antes de exercitar a regra.
config :api, Api.Storage,
  adapter: Api.Storage.Memory,
  account_id: "conta-de-teste",
  bucket: "bucket-de-teste",
  access_key_id: "chave-de-teste",
  secret_access_key: "segredo-de-teste"

# A foto do Google não é baixada de verdade na suíte: o `Req.Test` responde no lugar do
# `googleusercontent.com` (mesmo recurso do Zernio). Sem isto, o teste do job dependeria de rede.
config :api, Api.Accounts.AvatarSyncJob, plug: {Req.Test, Api.Accounts.AvatarSyncJob}

# E-mails vão para a caixa de teste (Swoosh.Adapters.Test); assert com Swoosh.TestAssertions.
config :api, Api.Mailer, adapter: Swoosh.Adapters.Test

# WhatsApp em memória (`test/support/whats_app_memory.ex`), e **desligado por padrão**.
#
# Desligado porque a maior parte da suíte foi escrita quando o e-mail era o único canal, e ligar
# o WhatsApp globalmente mudaria o canal de centenas de asserções que falam de `Swoosh` — sem
# testar nada de novo. Quem exercita o WhatsApp liga a chave no próprio teste
# (`Application.put_env`), que é também o que documenta "este teste é sobre o outro canal".
config :api, Api.Messaging.Transport,
  whatsapp_habilitado: false,
  whatsapp_adapter: Api.Messaging.WhatsAppMemory

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :api, ApiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "PL3h8Fw6FJ+TW9GXy2eNCjXw4jZxBKqMVkVfP59oxXFrjshPnJKBIwJJlMWf4WeB",
  server: false

# Traces na suíte (doc 76): processador SÍNCRONO, exportador continua `:none` (config.exs).
#
# `:simple` exporta cada span assim que ele fecha, em vez de acumular em lote com temporizador. É
# o que torna `assert_receive {:span, ...}` determinístico — com o processador `:batch` do padrão
# o span sai até 5 s depois, e o teste ficaria intermitente da pior forma: verde na máquina de
# quem escreveu, vermelho no CI carregado.
#
# Quem troca o exportador por `{:otel_exporter_pid, self()}` é o próprio teste
# (`test/api/tracing_test.exs`), no `setup`.
config :opentelemetry, span_processor: :simple

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Métricas (doc 74): a COLETA fica LIGADA no teste, e só o servidor HTTP sai.
#
# A tentação é desligar o PromEx inteiro com `disabled: true`. Seria um erro do mesmo tipo do
# doc 49: um `router:` apontando para módulo renomeado, ou um plugin incompatível com a versão
# do Oban, não levanta exceção — apenas deixa de produzir a série. Com a coleta ligada, o
# `prom_ex_test.exs` gera tráfego real e exige as famílias de métrica de volta; com ela
# desligada, a suíte ficaria verde sobre um `/metrics` vazio.
#
# O servidor sai porque porta é recurso global: `async: true` em dezenas de arquivos brigaria
# por 4021, e o teste que perdesse a corrida falharia por `:eaddrinuse` — ruído que não tem nada
# a ver com a regra sob teste.
config :api, :metrics, server?: false, port: 4021

# Dois grupos de métrica saem NO TESTE — e só nele. Cada um custou um defeito medido:
#
#   * `:oban_queue_poll_metrics` — o poller (`Api.PromEx.Poller.5000`) consulta `oban_jobs` de 5
#     em 5 segundos a partir de um processo que não é dono de conexão no
#     `Ecto.Adapters.SQL.Sandbox`. Sai `DBConnection.OwnershipError`, e não é só barulho: o
#     poller CHECA UMA CONEXÃO do pool, disputando com o teste que estiver rodando. Falha por
#     sorteio é a pior regressão para depurar meses depois.
#
#   * `:phoenix_channel_event_metrics` e `:phoenix_socket_event_metrics` — o `Phoenix.ChannelTest` monta o socket com
#     `transport: {Phoenix.ChannelTest, pid}`, uma TUPLA, e o coletor recusa valor de label que
#     não vira texto: centenas de "Dropping aggregation for bad tag value" por execução, no meio
#     das quais uma falha de verdade passa despercebida.
#
# São DOIS grupos para o mesmo defeito do transport, e descobri isso medindo: descartar só o de
# canal derrubou o ruído de centenas para 7 linhas, e as 7 restantes eram
# `socket.connected.duration`, do grupo vizinho. Contar o que sobrou é o que separa "melhorou"
# de "resolveu".
#
# Os três são artefato do ARNÊS, não defeito de produção — no container de dev, com WebSocket e
# Oban reais, nenhum dos dois avisos apareceu em duas horas de log. Em produção os dois grupos
# são justamente o que alimenta os painéis "Filas do Oban" e as métricas de canal.
#
# O que NÃO sai: HTTP, Ecto e eventos de job do Oban. São eles que fazem um `router:` renomeado
# reprovar em `prom_ex_test.exs` em vez de esvaziar um painel semanas depois.
config :api, Api.PromEx,
  disabled: false,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [
    :oban_queue_poll_metrics,
    :phoenix_channel_event_metrics,
    :phoenix_socket_event_metrics
  ],
  grafana: :disabled,
  metrics_server: :disabled
