import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/api start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :api, ApiWeb.Endpoint, server: true
end

config :api, ApiWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Google OAuth (ADR-015) — lido no boot em TODOS os ambientes (dev/test/prod), então basta
# setar as envs e reiniciar (sem recompilar). O `Api.Secrets` lê deste `:google_oauth`.
config :api, :google_oauth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET"),
  # BASE — o AshAuthentication anexa "/user/google/callback".
  #
  # O default de localhost vale só FORA de produção (doc 96, C-1). Em produção ele era um destino
  # de redirect de OAuth apontando para a máquina do desenvolvedor: o login por Google
  # simplesmente não fechava, e nada acusava — o Google recusa o `redirect_uri` e o usuário vê
  # uma tela de erro do Google, não do sistema.
  redirect_uri:
    System.get_env("GOOGLE_REDIRECT_URI") ||
      if(config_env() == :prod, do: nil, else: "http://localhost:5173/auth")

# Cloudflare R2 (anexos, doc 51). Fora do teste: lá o adaptador é `Api.Storage.Memory` e
# sobrescrever as chaves aqui apagaria a escolha de `config/test.exs` — `runtime.exs` roda
# DEPOIS dos configs por ambiente.
#
# As quatro variáveis são segredo (secrets do stack em produção, `.env` gitignored em dev). Sem
# elas o sistema sobe normalmente e só a fatia de anexos responde 503 — anexo não pode ser motivo
# de a clínica inteira não abrir.
if config_env() != :test do
  config :api, Api.Storage,
    adapter: Api.Storage.R2,
    account_id: System.get_env("R2_ACCOUNT_ID"),
    bucket: System.get_env("R2_BUCKET"),
    access_key_id: System.get_env("R2_ACCESS_KEY_ID"),
    secret_access_key: System.get_env("R2_SECRET_ACCESS_KEY")
end

# Comunicação com o paciente (doc 52). Fora do teste, pelo mesmo motivo do R2: lá o adapter é o
# `Swoosh.Adapters.Test` escolhido em `config/test.exs`, e `runtime.exs` roda DEPOIS.
#
# **Sem `RESEND_API_KEY` o sistema segue no adapter `Local`** — a caixa em memória de
# `/dev/mailbox`. É de propósito: em dev se quer ver a timeline funcionando ponta a ponta sem
# entregar e-mail de verdade a ninguém, e um `raise` aqui faria a API não subir por falta de uma
# chave que só produção precisa.
if config_env() != :test do
  # `not in [nil, ""]`, e a string vazia é o caso que importa: em Elixir **só `nil` e `false` são
  # falsos**, então `if System.get_env(...)` casava com `""` e escolhia o Resend sem chave. O envio
  # então estourava em `Swoosh.Adapter.raise_on_missing_config/2`.
  #
  # Não é hipótese: o `docker-compose.yml` define `RESEND_API_KEY: ${RESEND_API_KEY:-}`, ou seja a
  # variável SEMPRE existe no container — vazia quando não há valor no `.env`. Todo dev subido pelo
  # compose sem chave ficava com o magic link quebrado e `/dev/mailbox` vazio, contrariando o que
  # o comentário acima promete. Regressão em `test/api/mailer_config_test.exs`.
  if (api_key = System.get_env("RESEND_API_KEY")) not in [nil, ""] do
    config :api, Api.Mailer, adapter: Swoosh.Adapters.Resend, api_key: api_key

    # O adapter do Resend fala HTTP, e o `config.exs` desliga o cliente (`api_client: false`)
    # porque o `Local` não precisa dele. Sem esta linha o envio falha com um erro que não diz
    # isso — "api_client not configured".
    config :swoosh, :api_client, Swoosh.ApiClient.Finch
  end

  # O remetente é UM, e alimenta os DOIS módulos que mandam e-mail. Enquanto ele chegava só no
  # `PatientEmails`, os e-mails de conta saíam de uma constante do módulo
  # (`nao-responda@cinetra.local`) — domínio que não é verificado em provedor nenhum. Em produção
  # o Resend recusa com 403 antes de a mensagem existir, e o sintoma era o pior possível: e-mail de
  # paciente saindo normalmente, magic link não chegando, log limpo. Ninguém entrava no sistema.
  # Achado ao vivo em 2026-08-06; regressão em `test/api/mailer_config_test.exs`.
  #
  # E é um só de propósito: dois endereços seriam duas reputações de envio a aquecer e monitorar
  # para o mesmo produto, e a caixa do destinatário trata reputação por domínio.
  remetente =
    {System.get_env("MAIL_FROM_NAME") || "Cinetra",
     System.get_env("MAIL_FROM") || "nao-responda@cinetra.local"}

  config :api, Api.Messaging.PatientEmails, remetente: remetente
  config :api, Api.Accounts.Emails, remetente: remetente

  # Segredos de assinatura dos webhooks. Sem eles o endpoint recusa **tudo** — fail closed, e a
  # alternativa (aceitar sem verificar) seria um endpoint aberto de escrita cujo sintoma é nenhum.
  # Ver `ApiWeb.ResendWebhookController` e `ApiWeb.ZernioWebhookController`.
  config :api, Api.Messaging,
    resend_webhook_secret: System.get_env("RESEND_WEBHOOK_SECRET"),
    zernio_webhook_secret: System.get_env("ZERNIO_WEBHOOK_SECRET")

  # Fase 2 (doc 52 §9, doc 65): ligar o WhatsApp é configuração, não deploy de código novo.
  #
  # As duas chaves são independentes de propósito (ver `Api.Messaging.Transport`): a credencial
  # diz que **dá** para mandar, a flag diz que **deve**. Com credencial e sem flag, o canal fica
  # desligado e tudo sai por e-mail — que é o estado em que esta fatia nasce.
  config :api, Api.Messaging.Transport,
    whatsapp_habilitado: System.get_env("WHATSAPP_HABILITADO") == "true"

  config :api, Api.Messaging.Zernio,
    api_key: System.get_env("ZERNIO_API_KEY"),
    account_id: System.get_env("ZERNIO_ACCOUNT_ID"),
    base_url: System.get_env("ZERNIO_BASE_URL")
end

# Heartbeat dos crons (doc 62 §9). A URL vem de um monitor EXTERNO (healthchecks.io) e é opaca —
# não carrega dado nenhum, só identifica o check.
#
# **UMA env por ambiente**: `HEARTBEAT_BASE_URL` é a raiz com a chave do projeto
# (`https://hc-ping.com/<ping-key>`), e o slug de cada job entra abaixo, fixo em código. Assim o
# que distingue produção de homologação é a chave — não 14 colagens de UUID sem errar nenhuma.
#
# A chave do mapa é a string do worker porque é isso que o Oban põe no `job.worker`. O slug é o
# nome do check no healthchecks.io: **têm de bater**. Slug errado não fica calado — o serviço cria
# um check novo e o real deixa de receber sinal, então alarma no primeiro ciclo.
#
# `HEARTBEAT_URL_*` continua existindo para sobrescrever um job específico (URL por UUID, ou outro
# monitor). Precedência: URL explícita > slug.
config :api, Api.Heartbeat,
  base_url: System.get_env("HEARTBEAT_BASE_URL"),
  # Prefixo do slug por ambiente (`prod-`, `hml-`). Existe para que os dois stacks possam
  # compartilhar UMA chave de projeto e mesmo assim ter checks distintos — sem ele, o sinal do HML
  # manteria o check verde com a produção morta. Vazio quando cada ambiente tem projeto próprio.
  slug_prefix: System.get_env("HEARTBEAT_SLUG_PREFIX"),
  slugs: %{
    "Api.Notifications.DailyDigestJob" => "digest",
    "Api.Notifications.SessionSoonJob" => "session-soon",
    "Api.Housekeeping.PruneTrail" => "prune-trail",
    "Api.Housekeeping.PruneNotifications" => "prune-notifications",
    "Api.Housekeeping.PruneAttachments" => "prune-attachments",
    "Api.Housekeeping.PruneWebhookEvents" => "prune-webhook-events"
  },
  urls:
    %{
      "Api.Notifications.DailyDigestJob" => System.get_env("HEARTBEAT_URL_DIGEST"),
      "Api.Notifications.SessionSoonJob" => System.get_env("HEARTBEAT_URL_SESSION_SOON"),
      "Api.Housekeeping.PruneTrail" => System.get_env("HEARTBEAT_URL_PRUNE_TRAIL"),
      "Api.Housekeeping.PruneNotifications" =>
        System.get_env("HEARTBEAT_URL_PRUNE_NOTIFICATIONS"),
      "Api.Housekeeping.PruneAttachments" => System.get_env("HEARTBEAT_URL_PRUNE_ATTACHMENTS"),
      "Api.Housekeeping.PruneWebhookEvents" =>
        System.get_env("HEARTBEAT_URL_PRUNE_WEBHOOK_EVENTS")
    }
    |> Map.reject(fn {_worker, url} -> is_nil(url) or url == "" end)

# Porta do `/metrics` (doc 74). Só existe env aqui porque o Prometheus raspa por nome de
# container e porta fixa, e um dia dois stacks na mesma máquina podem precisar diferir.
#
# `server?` fica ligado em todo ambiente que não seja teste: em dev também, porque a maneira de
# descobrir que a coleta quebrou é abrir `/metrics` — e um dev que só descobre em produção não
# tinha observabilidade, tinha esperança.
if config_env() != :test do
  config :api, :metrics,
    server?: true,
    port: String.to_integer(System.get_env("METRICS_PORT", "4021"))
end

# ---- Traces (doc 76) ---------------------------------------------------------------------------
#
# UMA variável liga o terceiro sinal: `OTEL_EXPORTER_OTLP_ENDPOINT`. Sem ela o exportador segue
# `:none` (config.exs) e nada é enviado — que é o estado de quem não subiu observabilidade.
#
# O destino é o **Alloy**, não o Tempo. Os spans passam pelo agente pelo mesmo motivo que os logs:
# é lá que a poda de atributos mora, num lugar só, valendo para a API e para o BFF sem rebuild.
#
#     OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4317
#
# Nome do serviço e ambiente NÃO são configurados aqui de propósito: o SDK já lê `OTEL_SERVICE_NAME`
# e `OTEL_RESOURCE_ATTRIBUTES`, que são o padrão do OpenTelemetry e funcionam igual no BFF em Node.
# Reimplementá-los em Elixir criaria duas fontes de verdade para o mesmo rótulo.
otlp_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

# `config_env() != :test` é OBRIGATÓRIO aqui, e custou uma suíte quebrada para ficar claro: este
# arquivo roda em TODOS os ambientes, inclusive no `mix test`. Sem a guarda, ligar o trace em dev
# (a variável no `.env`) sobrescrevia o `span_processor: :simple` do `test.exs`, o
# `otel_simple_processor_global` deixava de existir e os testes de trace morriam com "no process".
#
# Falhava **verde no CI** — que não tem a variável — e vermelho só na máquina de quem ligou
# observabilidade. Que é a pior direção possível para uma quebra.
if config_env() != :test and otlp_endpoint not in [nil, ""] do
  # `:batch` acumula spans e despacha em lote. É o oposto do `:simple` da suíte, e aqui é o certo:
  # exportar um a um poria uma chamada de rede no caminho de cada requisição servida.
  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: :otlp

  config :opentelemetry_exporter,
    otlp_protocol: :grpc,
    otlp_endpoint: otlp_endpoint
end

# ---- Qual header de proxy merece confiança (bate-volta doc 90, H1) -----------------------------
#
# `ApiWeb.ClientIp` tem default vazio de propósito: nenhum header de vendor é confiável até que o
# deploy declare que a edge o **sobrescreve**. Esta é essa declaração.
#
# A env vem da MESMA variável do stack que alimenta o `ADDRESS_HEADER` do BFF
# (`CLIENT_IP_HEADER`, ver compose.dokploy.yml), e isso não é economia de digitação: a pergunta
# "qual header a edge garante?" é UMA, e enquanto ela teve duas respostas em dois arquivos, elas
# discordaram — o BFF confiando em `CF-Connecting-IP` e a lista daqui vazia, caindo no
# `x-forwarded-for`. A simetria está presa por `Api.DeployEnvTest`.
#
# **Por que o `x-forwarded-for` não basta atrás do Cloudflare**, mesmo com o firewall da origem já
# fechado nas faixas dele: o firewall prova que a requisição *passou* pela edge, não que a cadeia
# é honesta. O Cloudflare **acrescenta** ao XFF que o cliente mandou em vez de descartá-lo, e o
# `ClientIp` lê o primeiro elemento — que é, portanto, escrito pelo cliente. O `CF-Connecting-IP`
# é o oposto: sobrescrito a cada requisição.
#
# Vazia (o default do compose) = topologia sem edge conhecida, e aí o `x-forwarded-for` é o que o
# Traefik de fato garante no último hop.
# `config_env() != :test` pela mesma razão que o bloco de traces algumas linhas acima o exige: sem
# ele, uma variável solta no shell de quem roda a suíte passaria a decidir a cadeia de confiança, e
# os testes do default de `ApiWeb.ClientIp` diriam coisas diferentes em máquinas diferentes.
trusted_ip_header =
  System.get_env("TRUSTED_CLIENT_IP_HEADER", "") |> String.trim() |> String.downcase()

if config_env() != :test and trusted_ip_header != "" do
  config :api, trusted_client_ip_headers: [trusted_ip_header]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Fail-fast, como `SECRET_KEY_BASE` logo acima (doc 96, C-1). Com o default `"example.com"` a
  # aplicação **subia normalmente** em produção e: todo magic link redirecionava para
  # `https://example.com`, e o `check_origin` do WebSocket virava `["https://example.com"]` —
  # tempo real morto, com tudo verde no health check. É exatamente o modo de falha que o
  # comentário do `check_origin` (mais abaixo) descreve, e que ele não protegia.
  host =
    System.get_env("PHX_HOST") ||
      raise "environment variable PHX_HOST is missing (host público da API)."

  config :api, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :api, ApiWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  # D-R (doc 30) — o pool contra o fan-out do Oban, agora com a conta escrita.
  #
  # As filas do Oban **tiram do mesmo pool** que o HTTP e o WebSocket: um job em execução segura
  # uma conexão enquanto trabalha, e os nossos são todos ligados ao banco de ponta a ponta
  # (materialização de série, fan-out do sino, podas). Com `queues: [housekeeping: 2,
  # notifications: 5]`, **7** das conexões podem estar em job ao mesmo tempo — e com o pool em 10,
  # sobravam 3 para atender gente.
  #
  # Medido no dev (`pg_stat_activity`): `pool_size: 10` abre **11** conexões. A 11ª é o
  # `LISTEN "public.oban_insert"` do notifier do Oban, que fica **fora** do pool — some do
  # orçamento do pool, mas conta no limite do servidor.
  #
  # 16 = 7 (filas) + 8 (HTTP/WS) + 1 (o stager e os plugins do Oban, que também usam o pool).
  # `Api.ObanPoolTest` é o alarme: mexer nas filas sem mexer aqui deixa um teste vermelho.
  config :api, Api.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "16")

  config :api,
    token_signing_secret:
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

  # Destino do redirect pós-login (BFF SvelteKit). O :google_oauth é setado acima (todos os envs).
  # Idem: derivar do `host` é um default silencioso para a variável que decide **para onde o
  # login volta** e **qual origem o socket aceita**. Errar aqui não levanta nada — só deixa de
  # funcionar.
  web_app_url =
    System.get_env("WEB_APP_URL") ||
      raise "environment variable WEB_APP_URL is missing (origem do BFF, usada no redirect e no check_origin)."

  config :api, :web_app_url, web_app_url

  # O WebSocket da agenda (Entrega 3) é aberto pelo browser **do outro host**: o usuário está
  # no app web e o socket vai para a API. O default de `check_origin` é só o host do próprio
  # endpoint, então sem esta linha o Phoenix recusaria o upgrade — e o sintoma seria tempo real
  # morto em produção com tudo verde em dev, onde `check_origin: false` (dev.exs:22).
  config :api, ApiWeb.Endpoint, check_origin: [web_app_url]

  # Mailer de produção: configure aqui o adapter real (ex.: Swoosh.Adapters.Mailgun/SMTP)
  # via env quando houver provedor. Sem isso, o adapter Local do config.exs é usado.

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :api, ApiWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :api, ApiWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
