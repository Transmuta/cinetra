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
config :logger, level: :info

# Liga o rate limiting dos endpoints de auth (auditoria doc 13, causa A). Só em produção:
# o `ApiWeb.Plugs.RateLimitAuth` é no-op quando esta flag é falsa (dev/test).
config :api, rate_limit_enabled: true

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
