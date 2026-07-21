# 28 — Auditoria bate-volta: Entrega 4 (ciclo de vida)

Auditoria em rodadas da Entrega 4 da agenda (doc 25 §8d/§9), contra a **stack rodando** —
`mix test`/`ConnCase`, `psql` como `movimento_app` (NOBYPASSRLS), telemetria de query,
`EXPLAIN (ANALYZE, BUFFERS)` e `svelte-check`. Três eixos em paralelo (segurança, performance,
refatoração), cada achado provado por sonda.

**Onde parou:** rodadas 1 (checklist) + 2 (adversarial) fechadas nos três eixos; consolidação;
uma correção aplicada (rodada 3); rodada 5 (re-sonda + audita o diff da correção). Alvo: o diff
não-commitado da sessão (28 modificados + arquivos novos do ciclo de vida).

## 1. A varredura

| Eixo | Rodada 1 (checklist) | Rodada 2 (adversarial) acrescentou | Resultado |
| --- | --- | --- | --- |
| **Segurança** | A7/A9 na escrita, RLS/GUC, cross-tenant, mass-assignment, XSS de `obs`/`cancel_reason` | transição de **status** (não só reschedule) sobre bloco de colega; A9 no caminho `:reschedule`; cross-tenant com **id real** + `version` correta (vazamento por 409) | **0 CONFIRMADO** |
| **Performance** | índices dos reads, agregado `faltas` | cascata N+1 na turma; 3 transações por transição; fan-out do tempo real — os três só aparecem **contando queries no fluxo**, não lendo o diff | 3 CONFIRMADO (estruturais/bounded) |
| **Refatoração** | ações nomeadas, code interface, `with`, DRY do `mutate`/`statusActions` | preâmbulo repetido nas actions; `ACOES_DRAWER` hardcoded | 1 CONFIRMADO + 2 LOW |

### Segurança — tudo REFUTADO, com sonda

- **A7 na escrita:** `profissional` sobre bloco de colega → `{:error, :not_found}` nas cinco
  transições (o fetch de `transition_appointment` passa por `OwnAgendaOnly` e não acha);
  remarcar para a coluna de colega → `Ash.Error.Forbidden`. Provado por `mix test` probe.
- **A9 no `:reschedule`:** `encaixe: true` por `profissional` → `Forbidden` (`@encaixe_actions`
  inclui `:reschedule`). Sem encaixe → `{:ok, _}`.
- **RLS/GUC nas transições + cascata:** probe como `movimento_app` (`rolbypassrls=false`):
  `SET LOCAL movimento.clinic_id` antes de cada `UPDATE`; `appointments` e `attendances`
  (cascata) gravaram, versões inseridas, `WITH CHECK` não barrou. Leitura cross-tenant: GUC=A vê
  só A, 0 de B; sem GUC, 0 linhas.
- **Cross-tenant + vazamento pelo 409:** owner de A cancela id **real** de B com `version`
  certa (=1) e errada (+99) → **ambos** `{:error, :not_found}` (o fetch nega antes do guard de
  versão rodar → sem sinal diferencial). B intacto.
- **Mass-assignment:** introspecção Ash confirma o `accept` mínimo de cada ação; `status`,
  `version`, `clinic_id`, `encaixe` (atributo), `pkg_hold`, `package_id` **não** entram do corpo.
- **XSS:** `{appt.obs}`/`{appt.cancel_reason}` são interpolação Svelte escapada; nenhum `{@html}`
  no diff (verificado por leitura — a sonda de backend não alcança o `web/`).

## 2. As causas-raiz e o que foi feito

### Corrigido (rodada 3) — DRY #12: `RescheduleModal` duplicava `NewAppointmentModal`

O bloco conflito-erro-encaixe (caixa de erro com `TriangleAlert` + botão "Marcar como encaixe",
e o checkbox "Encaixe") estava copiado **verbatim** entre os dois modais — exatamente o tipo de
repetição que o projeto extrai em `Field`/`Modal`/`mutate`.

**Correção:** extraídos `ConflictErrorBox.svelte` e `EncaixeCheckbox.svelte` em
`lib/components/agenda/`; os dois modais passam a consumi-los. Zera as três cópias e garante que
a estética do 422-com-saída não divirja entre criar e remarcar.

**Re-sonda (rodada 5):** `svelte-check` 0 erros; os 22 testes de `NewAppointmentModal` (fatia
Entrega 1) **continuam verdes** (a dedup não regrediu o feature já entregue); suíte web 919/0,
gate de cobertura verde (branch 78,2% > 75%). O diff da correção é dois componentes de
apresentação sem endpoint, query ou `{@html}` novos — nada acende nas listas.

## 3. Decisão humana, ponto a ponto (2026-07-20)

Nenhum de segurança. Os itens foram levados um a um; o veredito de cada:

1. **Cascata N+1 por participante** (`cascade_to_attendances.ex`) — **ADIADO.** Uma transição de
   turma custa `3N` queries de escrita (por participante: `SET GUC` + `UPDATE` + `INSERT` na
   trilha), numa transação só. *Sonda:* 19→25 queries de turma de 1→3. `Ash.bulk_update` **não
   colapsaria**, porque `:transition` é `require_atomic? false` (`SetTenantGuc` before_action) →
   estratégia `:stream` → re-roda os hooks por registro; e a trilha por participante (A-D14)
   exige um `attendances_versions` por linha. Bounded pela capacidade da turma. *Se for mexer:*
   caminho de escrita que dispense o `SetTenantGuc` global da `Attendance` + teste de teto com
   `Api.QueryCounter`.
2. **Reload em transação separada** (`scheduling.ex`, `load_attendances`) — **ADIADO.** Round-trip
   (tx3) após o commit; nas ações de status a cascata já leu as attendances (cópia desanexada).
   Bounded (1 transação, não escala). *Se for mexer:* devolver as attendances do `after_action` e
   bifurcar status × reschedule.
3. **Fan-out do tempo real** (`load_visible_appointment` por assinante) — **MEDIDO** (stress
   local, `movimento_app`, bloco turma de 8 = o mais pesado). Uma releitura: **~9 ms / 3 SELECTs**.
   Uma escrita dispara K releituras concorrentes (gargalo = `pool_size` 10):

   | K assinantes | parede | queries/escrita |
   | --- | --- | --- |
   | 1 | 8 ms | 3 |
   | 10 | 16 ms | 30 |
   | 25 | 35 ms | 75 |
   | 50 | 61 ms | 150 |
   | 100 | 116 ms | 300 |
   | 200 | 234 ms | 600 |

   **Veredito:** linear e bounded. Para o K real (um punhado de pessoas olhando o **mesmo dia** da
   **mesma clínica** — 3 a 10), o custo é 8–16 ms e 9–30 queries por escrita: irrelevante. Só
   incomoda em K≥100, concorrência implausível para uma clínica. Fica como está (a releitura
   por-escopo é o que mantém a A7 correta por construção, R-D1); só reabrir se um K real medido em
   produção contradizer isto.
4. **DRY: preâmbulo repetido nas actions** (`+page.server.ts`) — **CORRIGIDO** (pós-auditoria).
   Extraído `submission/2` (lê o corpo, exige `id`, devolve `{form, id}` ou o `fail`); as três
   actions com corpo e o `transition/3` passam por ele. `svelte-check` 0, `page.server.test.ts`
   43/0.
5. **DRY: `ACOES_DRAWER` hardcoded** (`AppointmentDrawer.svelte`) — **CORRIGIDO** (pós-auditoria).
   Movido para `DRAWER_ACTIONS` em `$lib/agenda` (fonte única, arquivo testado); o drawer importa.
   `AppointmentDrawer` 8/0.

Web após 4 e 5: 919 testes, gate de cobertura verde (branch 78,4%). Os dois consertos são de
apresentação/roteamento, sem endpoint, query ou render novos.

### Notas (não são achados)

- O teardown efetivo do WebSocket vivo no sign-out depende do mecanismo canônico do Phoenix
  (`Endpoint.broadcast(topic_do_id, "disconnect", %{})`, que é o usado); provado que
  `current_user` existe e que o broadcast não quebra o sign-out (204), mas a derrubada de uma
  conexão viva exigiria um cliente WS real — fora do alcance das sondas de backend.
- `expected_version` ausente pula o guard de locking otimista (por design, para seed/chamada
  interna). Não contorna authz nem tenant, e a exclusion constraint segue barrando
  dupla-marcação.
