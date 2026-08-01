import Config

# Sem `force_ssl` na API, de propósito. Nesta topologia a API é **interna**: quem fala com ela é
# o BFF SvelteKit, por `http://api:4000` (rede interna do compose), sem `x-forwarded-proto` —
# `force_ssl` redirecionaria essas chamadas server-to-server para https e quebraria o BFF. Quem
# termina TLS e redireciona http→https é o Traefik do Dokploy (`compose.dokploy.yml`), ver docs/59.
#
# **O HSTS não vem daqui nem do proxy** (H59, Onda 5). Este comentário já descreveu um proxy Caddy
# que não existe mais e atribuiu o HSTS a ele; depois o docs/17 atribuiu à edge do Fly (que também
# já saiu). As duas versões estavam erradas: nenhum proxy emite `Strict-Transport-Security`. Quem o
# faz é o
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
#
# O formatter é NOSSO (`Api.LogFormatter`), e não o `LoggerJSON.Formatters.Basic`, por um motivo
# medido: o Basic aninha tudo sob a chave `metadata`, o `| json` do Loki achata isso com `_`, e o
# rótulo real virava `metadata_status`. Os treze dashboards perguntavam por `status` — e consulta
# certa sobre campo inexistente devolve ZERO linhas, não erro. Em produção, todo painel de 4xx
# abria "No data" com o log inteiro presente no Loki (doc 99). Ver o moduledoc de lá para o
# contrato dos campos.
config :logger, :default_handler,
  formatter: {
    Api.LogFormatter,
    # A SEGUNDA camada da redação. A primeira roda na origem (`Api.LogRedacao.redigir/2`, no
    # `RequestLogger`) e cobre o payload; esta cobre a linha INTEIRA, de qualquer ponto do
    # sistema — um `Logger.info("...", cpf: valor)` escrito daqui a seis meses em outro módulo
    # sai redigido sem que ninguém tenha de lembrar disso.
    metadata: [
      :request_id,
      # O elo com o Tempo (doc 76). Esta é a lista que VALE em produção — ela sobrescreve a do
      # `config.exs`, e é dela que sai o JSON que o Alloy embarca e o Loki indexa. Sem a chave
      # aqui, o `derivedFields` do Grafana não encontra `trace_id` na linha e o botão "Ver trace"
      # não aparece, com o trace existindo do outro lado e ninguém percebendo.
      :trace_id,
      :clinic_id,
      :actor_id,
      :method,
      :route,
      :status,
      :duration_ms,
      # Quem bateu na porta (doc 96, O-1). É o único identificador de origem que existe num
      # 401/429 anônimo, onde `clinic_id` e `actor_id` são nulos por definição — sem ele a
      # defesa contra brute-force funciona e não pode ser auditada. Também carimba as linhas
      # de `rate_limit` e do plug de verificação de token, que passaram a emiti-lo.
      :client_ip,
      # O que foi enviado e o que foi devolvido, **só em 4xx/5xx** (ADR-025). Sem estas três
      # chaves aqui o `RequestLogger` produz os campos e o formatter os descarta em silêncio —
      # a mesma armadilha que matou o `trace_id` uma vez (doc 76 §7.6).
      :payload,
      :query,
      :response
    ],
    redactors: [{Api.LogRedacao, []}]
  }

# Liga o rate limiting: o dos endpoints de auth (auditoria doc 13, causa A) e o global de
# 200 req/min (`RateLimitGlobal`) nos demais endpoints. Só em produção: os dois plugs são
# no-op quando esta flag é falsa (dev/test).
config :api, rate_limit_enabled: true

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
