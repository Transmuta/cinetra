# Instruções do projeto Cinetra

## Documentação e saídas — SEMPRE local, NUNCA cloud

- **NUNCA criar Artifacts nem publicar nada no claude.ai / cloud.** Não usar a ferramenta de Artifact em hipótese alguma, a menos que o usuário peça explicitamente com essas palavras. O usuário nunca pediu artefato.
- **Toda documentação, resumo, relatório ou entregável fica no repositório**, como arquivo local — normalmente um `.md` em `docs/`, seguindo a convenção dos arquivos existentes (`00-decisoes.md`, `01-dominio-ash.md`, …).
- Não enviar conteúdo do projeto para nenhum serviço externo (upload, publicação, indexação). Se algo exigir sair do repositório, **perguntar antes**.
- Arquivos temporários de trabalho podem ir para o scratchpad da sessão, mas o entregável final é sempre um arquivo no projeto.

## Bug encontrado → teste de regressão, SEMPRE

**Todo bug que aparecer vira um teste antes de virar conserto.** Sem exceção — bug que eu
mesmo achei, bug relatado pelo usuário, achado de bate-volta, regressão pega ao vivo no
browser ou no `psql`. A ordem é:

1. **Escrever o teste que falha** reproduzindo o bug — e **rodar para ver vermelho**. Teste
   que passa antes do conserto não prova nada; se ele já está verde, ele não reproduz o bug.
2. **Consertar** o código de produção.
3. **Rodar de novo para ver verde**, e rodar a suíte inteira para garantir que o conserto não
   quebrou vizinho.

Regras que essa prática carrega:

- **O teste fica na camada onde o bug morava.** Bug de regra de domínio → `api/test/api/...`
  pela code interface do domínio. Bug de contrato HTTP/422/status → teste de controller. Bug
  que só aparece atravessando a fronteira (string do JSON vs `%Date{}` do domínio) → **teste
  que atravessa a fronteira**; teste de unidade do lado de dentro já provou que não pega.
- **Bug de RLS/GUC/tenant não se prova com `mix test`** — a suíte roda como superusuário e é
  cega para isso. Use o gate `--only rls` **com as env vars de `DATABASE_USER=cinetra_app`**
  (ver "Comandos" abaixo — sem elas o gate roda como `postgres` e não prova nada) e/ou a
  verificação ao vivo. Ver `.claude/rules/migrations.md` e as lições dos docs de bate-volta.
- **Nunca "conserto agora e cubro depois".** O commit que entra na branch já traz o teste.
- Se por algum motivo o bug for realmente intestável de forma automatizada, **diga isso
  explicitamente** no relatório, com o porquê, e registre em `docs/50-debitos-tecnicos.md` —
  não deixe passar em silêncio.

Isso é o mesmo espírito do TDD em [`.claude/rules/testes.md`](.claude/rules/testes.md), só que
aplicado ao caso do bug: o teste é o que garante que ele **nunca mais volte**.

## Mapa do repositório — vá direto, não procure

Tabela de gatilhos: **o assunto do pedido → o arquivo**. Abra o alvo primeiro; só use busca
ampla se o alvo não bastar. Um domínio Ash sempre tem dois pontos de entrada:
`api/lib/api/<dominio>.ex` (o domínio + code interface — **comece por ele**, é o índice das ações)
e `api/lib/api/<dominio>/` (recursos, changes, validations, preparations, jobs).

### Backend — `api/lib/api/`

| Assunto no pedido | Domínio |
| --- | --- |
| login, magic link, Google, sessão, convite, papel/RBAC, clínica, membro, usuário | `accounts/` — `user`, `clinic`, `membership`, `token`, `user_identity`, `invites`, `role` |
| trilha, auditoria, quem-mexeu, `audit_events`, dado sensível redigido | `audit/` — `event`, `capture`, `sensiveis`, `resource_kind` |
| profissional, tipo de atendimento, sigla, cor | `directory/` — `professional`, `appointment_type` |
| WhatsApp, Zernio, e-mail ao paciente, lembrete, template, opt-out, webhook, resposta | `messaging/` — `zernio`, `dispatch`, `templates`, `reminder_job`, `webhooks`, `message` |
| sino, notificação in-app, badge, fan-out, digest | `notifications/` — `notification`, `feed`, `fanout` |
| pacote, série, N sessões, materialização, prévia, ação em massa | `packages/` — `package`, `series`, `materializer`, `preview`, `bulk` |
| paciente, ficha, CPF, tags, anexo | `records/` — `patient`, `attachment` |
| agendamento, agenda, horário da clínica/profissional, exceção, status, falta, turma/presença, exclusão | `scheduling/` — `appointment`, `attendance`, `clinic_hours`, `professional_hours`, `schedule_exception`, `availability`, `impact_analysis` |
| upload, bucket, R2, URL assinada | `storage/` — `r2`, `sig_v4` |
| RLS, GUC, `in_clinic`, tenant | `tenancy/set_tenant_guc.ex` |
| fila de espera, vaga, quem cabe, encaixe, candidato | `waitlist/` — `waitlist_entry`, `slot_finder`, `availability_rule` |
| poda, retenção, expurgo | `housekeeping/` |
| rate limit, 429 | `rate_limiter/` + `api_web/plugs/rate_limit_*.ex` |

Fora dos domínios: `repo.ex`, `scope.ex` (actor+tenant), `release.ex` (migrations no deploy),
`cnpj.ex`, `texto.ex`, `pagination.ex`, `params.ex`, `secrets.ex`, `heartbeat.ex`.

### Backend HTTP/WS — `api/lib/api_web/`

- **rota nova / 404 / verbo** → `router.ex` (mapa de tudo).
- **endpoint REST** → `controllers/<recurso>_controller.ex` (nome bate com o domínio).
- **tempo real, WebSocket, canal, presença** → `channels/` (`agenda_channel`, `notification_channel`,
  `waitlist_channel`, `channel_scope`, `user_socket`) + `presence.ex`, `realtime_token.ex`.
- **plug, autenticação de request, escopo, rate limit** → `plugs/` (`load_scope`,
  `verify_token_subject`, `rate_limit_auth`, `rate_limit_global`, `cache_raw_body`).
- **escopo de tenant no controller** → `tenant_scope.ex`. **log/telemetria** → `request_logger.ex`,
  `telemetry.ex`. **socket/endpoint** → `endpoint.ex`.
- **variável de ambiente, URL, segredo, `check_origin`, config de produção** → `api/config/runtime.exs`
  (dev: `dev.exs`); é lá que mora quase toda decisão por ambiente.

### Frontend — `web/src/`

| Assunto | Onde |
| --- | --- |
| tela, URL, `+page.svelte`/`+page.server.ts` | `routes/(app)/<slug>/` — `agenda`, `pacientes`, `profissionais`, `fila`, `relatorios`, `notificacoes`, `perfil`, `configuracoes/{clinica,equipe,horario,excecoes,tipos,comunicacao,auditoria}` |
| login, callback, sign-out, trocar clínica | `routes/auth/*` + `routes/{entrar,criar-conta,confirmar,comecar}` |
| endpoint do BFF chamado por fetch do browser | `routes/api/*` (`cep`, `patients/lookup`, `realtime/token`, `client-error`) |
| **chamada ao backend Elixir** (fetch server-side, tipos do contrato) | `lib/server/<recurso>.ts` — um por recurso, cada um com `.test.ts` ao lado |
| lógica pura testável (formatação, máscara, layout da grade, conflito, querystring) | `lib/<assunto>.ts` + `.test.ts` |
| componente de tela | `lib/components/` — raiz é o design system (`Button`, `Modal`, `Drawer`, `Field`, `ConfirmDialog`, `Toast`, `SubmitButton`); subpastas por área (`agenda/`, `fila/`, `patients/`, `professionals/`, `members/`, `shell/`, `audit/`) |
| menu, sidebar, rail, topbar, navegação | `lib/components/shell/` (`nav.ts` é o mapa de itens) |
| cookie de sessão, guarda global, CSP/HSTS | `hooks.server.ts` + `lib/csp.js` + `svelte.config.js` (CSP do Kit é build-time) |
| token, design token, cor, raio, dark mode | `lib/styles/app.css` e `lib/styles/cinetra.css` |

### Docs, infra, protótipo

- `docs/NN-*.md` — numerados em ordem cronológica; **`bate-volta`/`auditoria` no nome = relatório de
  auditoria daquela fatia** (achados e o que ficou pendente). Fatia nova → doc de plano, depois doc de
  bate-volta. `00-decisoes.md` e `50-debitos-tecnicos.md` são os acumuladores.
- `.claude/rules/` — `ash*.md`, `usage_rules_*.md` vêm dos pacotes; `migrations.md` e `testes.md` são
  **regras próprias do projeto** (leia antes de mexer em migration ou de abrir PR).
- `deploy/` — `observability/` (Alloy/Grafana), `backup/`, `carga/`, `bff-test/`. Os composes ficam na
  **raiz**, não em `deploy/`: `compose.dokploy.yml` é prod/HML, `compose.prod.yml` e
  `compose.bff-test.yml` são os auxiliares, `docker-compose.yml` é o de dev.
- `interface/` — protótipo HTML da marca; **é regenerado por ferramenta, não edite à mão**.
- migrations: `api/priv/repo/migrations/` (geradas por `mix ash.codegen`, nunca escritas à mão).

## Comandos

Tudo roda em container; do host use `docker.exe compose exec` (serviços `api`, `web`, `db`).

> **O container do `api` roda com `MIX_ENV=dev`, então passe `-e MIX_ENV=test` para toda tarefa de
> teste** — `docker.exe compose exec -T -e MIX_ENV=test api mix test`. Sem isso o `mix test` sobe a
> aplicação em dev e morre em `:eaddrinuse`: o servidor de métricas do PromEx já está com a 4021, e
> em `test` ele é desligado (`config/test.exs`). O erro não menciona teste nem ambiente, então
> custa caro descobrir. (Para um `mix run` avulso em dev, o equivalente é `-e METRICS_PORT=4099`.)

```bash
# backend (dentro de api/)
mix test                      # suíte
mix test test/api/x_test.exs:42
mix coveralls                 # suíte + gate de cobertura (o CI usa este)
# gate de RLS — as env vars NÃO são opcionais: sem elas o mix conecta como `postgres`
# (o default de config/test.exs), que bypassa RLS, e a rodada dá verde sem exercitar
# policy nenhuma. O próprio teste recusa rodar sob outro role desde então.
DATABASE_USER=cinetra_app DATABASE_PASSWORD=cinetra_app SKIP_DB_SETUP=1 mix test --only rls
mix format --check-formatted && mix compile --warnings-as-errors
mix ash.codegen --dev         # iterar; no fim, mix ash.codegen <nome_da_mudanca>

# web (dentro de web/)
npm run check                 # svelte-check
npm run test:unit             # Vitest
npm run coverage              # Vitest + thresholds (o CI usa este)
npm run test:e2e              # Playwright
```

O gate real é [`.github/workflows/ci.yml`](.github/workflows/ci.yml): jobs `api` (coveralls),
`api-rls`, `web` (check + coverage + build).
