import Config

# Sem `force_ssl` na API, de propósito. Nesta topologia a API é **interna**: quem fala com ela é
# o BFF SvelteKit, por `http://movimento-api.internal:4000` (rede privada 6PN do Fly), sem
# `x-forwarded-proto` — `force_ssl` redirecionaria essas chamadas server-to-server para https e
# quebraria o BFF. Quem termina TLS e redireciona http→https é a edge do Fly (`force_https` no
# `fly.toml`), ver docs/17.
#
# **O HSTS não vem daqui nem da edge** (H59, Onda 5). Este comentário já descreveu um proxy Caddy
# que não existe mais e atribuiu o HSTS a ele; depois o docs/17 atribuiu à edge do Fly. As duas
# versões estavam erradas: o proxy do Fly não emite `Strict-Transport-Security`. Quem emite é o
# BFF (`web/src/hooks.server.ts`), que é quem o browser de fato acessa — a API só recebe
# WebSocket do browser, e HSTS em resposta de WebSocket não protege navegação nenhuma.

# Do not print debug messages in production
#
# **O nível `:info` é o que torna 30 dias de retenção barato** (doc 62 §1). O Ecto loga query em
# `:debug`, então em produção o SQL não aparece — e uma tela de agenda dispara dezenas de queries.
# Baixar isto para `:debug` multiplicaria o volume por uma ordem de grandeza e estouraria o
# dimensionamento do doc 62 §2. Se um dia for preciso ver SQL em produção, que seja por amostragem
# temporária, nunca por nível global.
config :logger, level: :info

# Log em JSON, uma linha por evento (doc 62 §7.1) — é o que o agente coleta e o Loki indexa.
# Só em produção: em dev, texto colorido é melhor para humano.
config :logger, :default_handler,
  formatter:
    {LoggerJSON.Formatters.Basic,
     metadata: [:request_id, :clinic_id, :actor_id, :method, :route, :status, :duration_ms]}

# Liga o rate limiting: o dos endpoints de auth (auditoria doc 13, causa A) e o global de
# 200 req/min (`RateLimitGlobal`) nos demais endpoints. Só em produção: os dois plugs são
# no-op quando esta flag é falsa (dev/test).
config :api, rate_limit_enabled: true

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
