# 32 — Bate-volta: notificações in-app

Auditoria em rodadas da fatia [`31-notificacoes.md`](31-notificacoes.md), contra a stack rodando
(`docker compose`: db + api + web). Três caças em paralelo (segurança → `quality-specialist`,
performance → `data-engineer`, refatoração → `test-engineer`), cada achado provado por sonda.

## 1. Onde parou

Rodadas 1+2 (caça) fecharam com **zero achados de segurança**, um punhado de perf medido e três
de refatoração. Consertei o barato/claro (rodada 3), re-sondei (rodada 5) e deixei o estrutural
para decisão. Não houve rodada 4 — a 3 fechou a fila.

## 2. A varredura

| Eixo | Item | Estado | Sonda |
| --- | --- | --- | --- |
| **Seg** | Isolamento por tenant (RLS) | REFUTADO | `psql -U movimento_app` + GUC da clínica B → 0 linhas; A → 4; sem GUC → 0 |
| **Seg** | Vazamento por-usuário (mesma clínica) | REFUTADO | notif. injetada p/ outro recipient não aparece no GET da sessão (RLS deixa clínica passar=5, policy `recipient_id==actor` recorta=4) |
| **Seg** | Canal WebSocket | REFUTADO | tópico de outra clínica → unauthorized; vínculo revogado → recusa; caixa alheia não vaza (`refute_push`); 6 testes |
| **Seg** | Fan-out recipient/tenant | REFUTADO | `active_memberships` filtra clinic+status; tenant = clínica do evento; supressão do autor OK |
| **Seg** | IDOR no mark_read | REFUTADO | id alheio → **404**, `read_at` intacto; `read-all` → `{"marked":0}` |
| **Seg** | XSS no web | REFUTADO | zero `{@html}` em `web/src`; Svelte escapa title/body |
| **Perf** | Badge lê não-lidas 2× por navegação (double-read) | **CONFIRMADO** | `?unread=1` → 2 SELECT idênticos; `unread_count` = `list \|> length` |
| **Perf** | `who_fits` em todo cancel/falta (fila vazia inclusa) | **CONFIRMADO** | telemetria: `slot_maybe_opened(:cancel)` = 6 queries + transação, mesmo com fila vazia |
| **Perf** | Clínica lida 2× por notificação (entrega) | **CONFIRMADO** | `appointment_touched` = 7 queries, 2 `SELECT clinics` p/ a mesma clínica |
| **Perf** | `unread_count` traz linhas + `length()` | **CONFIRMADO** | log: `SELECT n0.data,…` de todas as não-lidas p/ contar |
| **Perf** | `mark_all_read` O(N) round-trips | CONFIRMADO (estrutura) | `Enum.each(&do_mark_read!)`: 1 SELECT + N×(auth+UPDATE) em série |
| **Perf** | Lista sem LIMIT/paginação + sem poda | volume-dependente | ação `:read` sem `pagination`; tabela sem expurgo |
| **Perf** | `ORDER BY inserted_at` é Sort | volume-dependente | EXPLAIN: Index Scan + Sort separado; bounded por usuário |
| **Perf** | FK sem índice | REFUTADO | `pg_indexes`: `recipient_id` próprio; `clinic_id` no prefixo do composto |
| **Refat** | `npm run check` quebrado | **CONFIRMADO** | 4 erros em `page.svelte.test.ts` (mock `data` sem `theme`/`me`) — quebra o gate `check` do CI |
| **Refat** | `change fn` anônima no `mark_read` | CONFIRMADO | único `change fn` em todo `api/lib` (viola ash.md) |
| **Refat** | DRY `connectNotifications`≈`connectWaitlist` | CONFIRMADO | quase byte-a-byte, incl. renovação de token (lógica de segurança) |
| **Refat** | Aviso Ash "Missed notifications" no mark_read | CONFIRMADO | `mix test`: warning por marcação (efeito do fix de RLS: escrita dentro do `in_clinic`) |

**O que a rodada 2 (adversarial) acrescentou à 1:** as medições de perf por telemetria (queries por
evento) e o aviso Missed-notifications — nenhum apareceria numa leitura de checklist; só rodando o
fluxo e contando. A rodada 1 (checklist) deu a cobertura de segurança/DRY; a 2 deu os números.

## 3. Causas-raiz

- **A — Badge caro em toda navegação** (double-read + `length` em vez de `COUNT`). Alta frequência.
- **B — Fan-out pesado por evento** (`who_fits` incondicional + clínica 2×). Custo por cancel/falta.
- **C — Contrato de teste/rule quebrado** (`check` do CI + change anônima + aviso Missed).
- **D — DRY dos canais de sinal** (connect* e as guardas de `join` clonadas).

## 4. O que foi corrigido (rodada 3, re-sondado na 5)

| Causa | Correção | Diff | Re-sonda (rodada 5) |
| --- | --- | --- | --- |
| A | `unread_count` → `Ash.count!` (COUNT no banco) | `notifications.ex` | log: `SELECT coalesce(count(*),…) WHERE read_at IS NULL AND clinic_id=$ AND recipient_id=$` — e **recortado por destinatário** (diff-audit: não conta caixa alheia) |
| A | Controller deriva `unread` de `length` no caminho `?unread=1` | `notifications_controller.ex` | log: `?unread=1` → **1** SELECT (era 2) |
| B | Clínica lida 1× por notificação (fuso computado uma vez) | `fanout.ex` | 2 sites de `clinic_timezone` (1/função); `when_str`/`local_date_iso` não leem mais clínica |
| C | `page.svelte.test.ts`: `data` com `theme`/`me` (e sem `form`, que a tela não usa) | `page.svelte.test.ts` | `npm run check` → **0 erros** |
| C | `change fn` → módulo `StampReadAtOnce` | `notification.ex` + change nova | `grep "change fn" api/lib` → nada |
| C | `return_notifications?: true` + descarte no mark_read/all | `notifications.ex` | `mix test` → **sem** aviso Missed (recurso não tem assinante) |

Verificação final: **backend 709 testes / 91,1 % (gate exit 0)**, **web 1116 testes / 91,98 %
(gate exit 0)**, `/notificacoes` a 100 %. Nenhuma regressão.

**Diff-audit da rodada 3 (código novo é código não-auditado):** a única superfície nova é a query
`COUNT` do `unread_count` — sondada: sai com `clinic_id` **e** `recipient_id` no `WHERE`, então
herda o mesmo recorte por tenant+destinatário da leitura (sem vazamento). `StampReadAtOnce` é puro;
o descarte de notificações é correto (o recurso não tem `Ash.Notifier`). Sem achado novo.

## 5. O que ficou para você (não corrigido)

Estrutural ou volume-dependente — no espírito das dívidas D-* do [doc 30](30-decisoes-pendentes-agenda.md).

| # | O que é | Sonda | Por que não agora | Correção proposta |
| --- | --- | --- | --- | --- |
| **P1** | `who_fits` roda no notifier **síncrono pós-commit** de TODO cancel/falta — 6 queries + transação mesmo com fila vazia; soma latência à resposta do cancel | telemetria (6 queries, fila vazia) | **Estrutural**: mover fan-out para fora do caminho síncrono é decisão de arquitetura (Oban já existe no projeto) | Job Oban para o fan-out (assíncrono), OU guarda barata "fila não-vazia?" antes do `who_fits` |
| **P2** | `mark_all_read` O(N) round-trips (sem bulk) | `Enum.each` de updates individuais | Volume: pequeno hoje; `bulk_update` sob RLS+policy filter-check dentro do `in_clinic` precisa de teste próprio | `Ash.bulk_update` (`where recipient_id=$ and read_at is null`) em 1 round-trip |
| **P3** | Lista da caixa sem LIMIT/paginação + tabela sem poda | ação `:read` sem `pagination` | Volume: 4 linhas hoje; mesmo follow-up de Pacientes (doc 24) | paginação na `:read` + política de expurgo/retenção |
| **P4** | `ORDER BY inserted_at` é Sort (não coberto por índice) | EXPLAIN | Otimização; conjunto bounded por usuário | índice `[clinic_id, recipient_id, inserted_at desc]` e/ou parcial `where read_at is null` |
| **P5** | `active_memberships` lido 2× num cancel (appointment_touched + slot_maybe_opened) | logs | Barato (memberships é global e pequena); cai junto com P1 se o fan-out for repensado | memoizar por evento, ou resolver no redesenho de P1 |
| **D1** | DRY: `connectNotifications`≈`connectWaitlist` (incl. renovação de token) | leitura | Extrair toca **código vizinho** (waitlist), fora do alvo desta fatia | `connectSignalChannel(config, topic, event, handler, deps)` cobrindo os dois sinais |
| **D2** | Guardas de `join` (`same_clinic`/`active_member?`) clonadas em 3 canais | leitura | Clonagem-por-fatia aceita hoje; é a 2ª/3ª cópia de guarda de **autorização** | `use ApiWeb.TenantChannel` se surgir um 4º canal |

**Recomendação:** P1 é o único de custo por-evento que vale considerar antes de volume real (é
latência no cancel, não só query count) — mas a correção certa (síncrono→assíncrono) é decisão sua.
O resto é bounded e revisitável sob carga, como as dívidas do doc 30.
