import Config

config :api, token_signing_secret: "ZF5ezrg8Ok6/UlQajfAaSey6CAGa15cn"
config :bcrypt_elixir, log_rounds: 1

config :api, Api.Repo,
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  database: "movimento_test#{System.get_env("MIX_TEST_PARTITION")}",
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

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
