# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Base IANA de fusos (dep :tz). Sem isto `DateTime.new/4` devolve
# `{:error, :time_zone_not_found}` e o `Clinic.timezone` (ADR-009) não converte nada.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default?: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :authentication,
        :token,
        :user_identity,
        :json_api,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:json_api, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :api,
  generators: [timestamp_type: :utc_datetime],
  ecto_repos: [Api.Repo],
  ash_domains: [
    Api.Accounts,
    Api.Directory,
    Api.Scheduling,
    Api.Records,
    Api.Waitlist,
    Api.Packages,
    Api.Notifications,
    Api.Messaging,
    Api.Audit
  ],
  ash_authentication: [return_error_on_invalid_magic_link_token?: true]

# Oban — a fila `housekeeping` roda a materialização de série (Fatia 3) e as **podas**.
#
# O cron voltou com trabalho que de fato existe: `PruneTrail` uma vez por dia, às 03:00 UTC. O
# cron anterior (limpeza de `SlotHold`) foi removido porque varria por clínica a cada 5 min uma
# tabela que deixara de existir (doc 39) — o critério é esse, não "cron é ruim". A trilha, medida
# em 3× a tabela base sem nada que a diminuísse (doc 43 §5f), é o oposto: trabalho real, diário.
# A caixa do sino entrou pelo mesmo critério (#54): tabela que só crescia.
config :api, Oban,
  repo: Api.Repo,
  # `notifications` é fila própria (#52): o fan-out de "vaga livre" não pode ficar atrás de uma
  # poda que varre clínica a clínica por minutos — aviso de vaga que chega tarde não vale nada.
  queues: [housekeeping: 2, notifications: 5],
  plugins: [
    # A fila que executa as podas também precisava de uma. Sem isto, `oban_jobs` só cresce —
    # medido: 779 jobs `completed` acumulados em 4 dias de dev, e os crons da Onda 4 garantem
    # +314 linhas/dia. 7 dias é escolha humana: curto o bastante para a tabela não pesar, longo
    # o bastante para responder "por que o lembrete não saiu na terça".
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 3 * * *", Api.Housekeeping.PruneTrail},
       # 15 min depois da trilha, não junto: as duas varrem clínica a clínica e não há motivo
       # para disputarem pool na mesma madrugada.
       {"15 3 * * *", Api.Housekeeping.PruneNotifications},
       # Mais 15 min: a terceira poda da madrugada (doc 51). Recolhe upload abandonado — que
       # tem BYTES no R2 do outro lado, e por isso varre linha a linha em vez de DELETE em
       # lote — e a trilha de acesso a anexo.
       {"30 3 * * *", Api.Housekeeping.PruneAttachments},
       # Mais 15 min, e o mesmo motivo de desencontro. A quarta poda é a única sem clínica: a
       # tabela de corpos de webhook já vistos (doc 96, S-7) não tem tenant nenhum.
       {"45 3 * * *", Api.Housekeeping.PruneWebhookEvents},
       # #51 — lembretes por relógio. O resumo acorda de hora em hora porque "19h" é local de
       # cada clínica (ADR-009); só trabalha nas que estão na hora certa.
       {"0 * * * *", Api.Notifications.DailyDigestJob},
       # A cada 5 min, servindo a janela [+15, +20). É esta linha que desliga o "sessão em 15
       # min" caso a objeção do doc 31 §3d (ruído) se confirme no uso.
       {"*/5 * * * *", Api.Notifications.SessionSoonJob}
     ]}
  ]

# #51 — os dois lembretes por relógio. Números de produto, não de infra.
config :api, Api.Notifications.DailyDigestJob, hora: 19
config :api, Api.Notifications.SessionSoonJob, antecedencia_min: 15

# Retenção da caixa do sino (#54). Assimétrica de propósito: lida é histórico, não-lida é
# trabalho pendente — ver `Api.Housekeeping.PruneNotifications`. Mudar aqui é decisão humana.
config :api, Api.Housekeeping.PruneNotifications, reter_lidas_dias: 90, reter_dias: 365

# Quanto tempo a trilha de auditoria fica. **90 dias** (D-Aud5, doc 63), revogando os 365 do doc
# 43 §5f: com doze recursos auditados a trilha passou a ser a tabela que mais cresce, e a maior
# parte do que ela guarda nunca é lida.
#
# A consequência está registrada para a revisão com o jurídico: 90 dias vale igual para "quem teve
# acesso administrativo" e "quem leu o laudo", que são os registros que uma auditoria externa
# costuma pedir de anos anteriores. Por isso o número mora em `Api.Audit.retencao_dias/0` e esta
# linha é só o override — mudar a retenção é editar um número, não caçar constantes.
config :api, Api.Audit, retencao_dias: 90

# Magic link sem página de interação: o callback GET assina a sessão direto (09 §8).
config :ash_authentication, bypass_require_interaction_for_magic_link?: true

# Configure the endpoint
config :api, ApiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ApiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Api.PubSub,
  live_view: [signing_salt: "9DW1AgFi"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  # `clinic_id`/`actor_id` são carimbados pelo `LoadScope`; `route`/`status`/`duration_ms` vêm do
  # `ApiWeb.RequestLogger`. Em dev isto sai como texto legível; em prod, como JSON (prod.exs).
  metadata: [
    :request_id,
    # O elo com o Tempo (doc 76). Carimbado por `ApiWeb.Plugs.TraceMetadata` e lido pelo
    # `derivedFields` do datasource do Loki — sem esta chave na lista, o campo é descartado pelo
    # formatter e o botão "Ver trace" some do Grafana sem nenhum erro em lugar nenhum.
    :trace_id,
    :clinic_id,
    :actor_id,
    :method,
    :route,
    :status,
    :duration_ms
  ]

# **Desliga o logger de requisição do Phoenix** (doc 62 §7.1). Ele emite duas linhas por
# requisição (`GET /rota` + `Sent 200 in Xµs`) — medido: 41 linhas para 21 requisições. Quem loga
# no lugar é o `ApiWeb.RequestLogger`, com um evento só e os campos todos juntos.
config :phoenix, :logger, false

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Mailer (Swoosh). Default: adapter Local (caixa em memória, dev). Sobrescrito por
# env em test.exs/runtime.exs. Sem cliente HTTP externo (magic link só precisa de
# Local/Test/SMTP); adapters de API ficam para quando houver provedor real.
config :api, Api.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false

# Object storage dos anexos (doc 51, ADR-008): Cloudflare R2, bucket privado. As credenciais são
# SEGREDO e vêm por env em `runtime.exs` — aqui fica só o adaptador. Sem credencial,
# `Api.Storage.configured?/0` é falso e o endpoint devolve 503 em vez de oferecer um upload que
# não tem para onde ir.
config :api, Api.Storage, adapter: Api.Storage.R2

# Métricas Prometheus (doc 74). O que a APLICAÇÃO sabe sobre si mesma — BEAM, pool do Ecto,
# filas do Oban, latência por rota. Máquina e container vêm de fora (node_exporter/cAdvisor).
#
# `metrics_server: :disabled` **não** desliga as métricas: desliga só o servidor HTTP embutido do
# PromEx, que usa `Plug.Cowboy`. Quem serve o `/metrics` é um `Bandit` nosso, na árvore de
# supervisão (`Api.PromEx.metrics_server_children/0`) — mesmo servidor web do resto da aplicação,
# e uma dependência a menos.
#
# `grafana: :disabled` porque os dashboards deste projeto são ARQUIVO provisionado em
# `deploy/observability/dashboards/`, versionado junto com o resto. O upload por API do PromEx
# criaria painel que existe só no volume do Grafana — some ao recriar o container e não aparece
# em nenhum diff.
config :api, Api.PromEx,
  disabled: false,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: :disabled,
  metrics_server: :disabled

# A porta do `/metrics`. NÃO é publicada no compose — só o Prometheus, de dentro da rede do
# Docker, alcança. Ver o moduledoc de `Api.PromEx` para o porquê de não ser rota do router.
config :api, :metrics, server?: true, port: 4021

# Traces (doc 76): DESLIGADO por padrão, ligado em `runtime.exs` quando houver endpoint OTLP.
#
# O default do SDK é `traces_exporter: :otlp` apontando para `localhost:4317`. Deixá-lo assim
# faria toda instalação sem stack de observabilidade — dev de quem clonou o repositório, CI,
# a suíte — tentar exportar span para um endereço que não atende, num laço de reconexão barulhento.
# Falhar assim é pior que não instrumentar: gasta CPU, polui o log e não produz trace nenhum.
#
# `:none` não desliga a instrumentação: os spans continuam nascendo, medindo e sendo descartados
# no fim. Isso é de propósito — o caminho de código é o MESMO em todo ambiente, então um bug de
# instrumentação aparece na suíte, e não só em produção.
config :opentelemetry, traces_exporter: :none

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
