# 29 — Auditoria bate-volta: Entrega 5 (fila de espera)

Auditoria em rodadas contra a **stack rodando** do diff da Entrega 5 (doc [25](25-agenda.md) §8e):
domínio `Api.Waitlist` (`WaitlistEntry`, `AvailabilityRule`, `SlotFinder`), `Api.Scheduling.SlotHold`
+ o worker de limpeza do Oban, `offer`/`convert`/`who_fits`, o `WaitlistController` + rotas +
`WaitlistJSON`, `WaitlistNotifier` + `WaitlistChannel`, e o frontend em `web/src/.../fila` +
`realtime.ts`.

As três caças (segurança, performance, DRY/regras) foram despachadas **em paralelo** a subagentes
especializados, cada um com a ordem de **provar com sonda** (psql como `movimento_app`, `ConnCase`,
`EXPLAIN`, contagem de queries por telemetria). Nenhum achado sem output de sonda.

## 1. Onde parou

Parou na consolidação com **3 achados CONFIRMADOS para conserto** (1 segurança LOW, 1 performance
LOW, 1 DRY) + itens estruturais/de-negócio para decisão. Todo o resto — isolamento RLS, IDOR, a
corrida do hold, o canal, spoof de `held_by`, bypass de coluna, SQLi, vazamento de `clinic_id`,
N+1 — **defendido e provado**.

## 2. A varredura

### Segurança (14 itens; 1 CONFIRMADO LOW)

| Item | Estado | Sonda |
| --- | --- | --- |
| RLS nas 3 tabelas novas | REFUTADO (defende) | psql `movimento_app`: A→B = 0 linhas; INSERT/UPDATE de B sob GUC=A rejeitado |
| IDOR (slots/offer/convert/patch/delete de outra clínica) | REFUTADO | ConnCase: todos 404 |
| `profissional` faz `convert` na coluna de colega | REFUTADO | ConnCase: coluna alheia → 403; própria → 201 |
| Spoof de `held_by` no corpo do `offer` | REFUTADO | `meta.held_by.id == actor`, não o forjado |
| `find_slots`/`who_fits` (`authorize?: false`) vazam cross-tenant | REFUTADO | só entries de A; leitura `tenant:` + `in_clinic` |
| `meta` do 409 expõe hold de outra clínica | REFUTADO | `hold_meta` sob `in_clinic`; cross-clinic → meta vazio |
| Join do canal de outra clínica / vínculo revogado | REFUTADO | ChannelCase: unauthorized nos dois |
| Corrida do hold (constraint sem predicado de tempo) | REFUTADO | pg_constraint sem `WHERE`; overlap → `exclusion_violation` |
| `clinic_id` do corpo | REFUTADO | `whitelist` tira; RLS barra `WITH CHECK` |
| SQLi (`PurgeExpired`, `CleanupWorker`) | REFUTADO | parametrizado (`$1`, `Ecto.UUID.dump!`) |
| Policy de `AvailabilityRule` (`always()`) | REFUTADO | só via `manage_relationship` do pai já autorizado |
| Vazamento de `clinic_id` na serialização | REFUTADO | `refute resp =~ "clinic_id"` passou |
| Log de token/PII | REFUTADO | zero `Logger`/`dbg` no diff |
| **Referência cross-tenant não validada** | **CONFIRMADO (LOW)** | ConnCase: `offer` com `professional_id` de B → 201 |

**O que a caça adversarial (rodada 2) achou que a checklist não pegou:** o CONFIRMADO. A pergunta
"o que eu ganho se eu **mentir** o `professional_id`?" expôs a única aresta onde um id do cliente
cruzava a fronteira de tenant sem validação.

### Performance (6 concerns; 2 CONFIRMADOS LOW)

| Concern | Estado | Sonda |
| --- | --- | --- |
| `find_slots` 14d × profs escala | REFUTADO (saudável) | 10 queries p/ 2 **ou** 4 profs; `load_availability_window` = 6 queries independe de dias/profs |
| appointments read do motor | REFUTADO | `Index Scan` em `(clinic_id, starts_at)` sob escala (seq scan só porque a tabela tem 14 linhas) |
| `list_entries`/`who_fits` N+1 de paciente/faltas | REFUTADO (batched) | 5 queries p/ 7 entries; `faltas` = 1 `LATERAL` index-scan |
| `WaitlistNotifier` lê DB por evento | REFUTADO | zero query — usa `entry.clinic_id` do notification |
| **`availability_rules.clinic_id` sem índice** | **CONFIRMADO (LOW)** | `EXPLAIN` cascade → Seq Scan (forced-off idem) |
| **Oban cron O(clínicas)/min** | CONFIRMADO (LOW, estrutural) | `* * * * *`; 19 DELETEs/min; DELETE = seq scan de tabela minúscula |

### DRY / regras (7 DRY CONFIRMADOS; regras OK)

D1 (relógio da clínica 3× + `load_clinic` dobrado em `candidates`), D2 (`finish`/`parseIds`
idênticos fila↔agenda), D3 (`/pacientes` `+server` gêmeo), D4 (boilerplate de socket), D5 (projeção
de paciente em 2 domínios), D6 (alias faltando), D7 (`same_clinic/2`). **Nenhuma violação de regra**
(`ash.md`, `usage_rules_elixir.md`, `testes.md`) — REFUTADO/NÃO SE APLICA em todas.

## 3. As causas-raiz

1. **Referência de entidade cross-tenant sem validação** (segurança). Causa única, 2 sintomas: o
   `SlotHold.offer` aceitava `professional_id` de outra clínica (a **aresta afiada**: a exclusion
   constraint é global por ADR-017, então uma clínica podia negar por 10 min a reserva de vaga de
   outra), e o `WaitlistEntry.enqueue` aceitava `patient_id` de outra clínica (benigno: item-fantasma
   `patient: null` sob RLS, sem disclosure). O `clinic_id` sempre vinha do escopo (correto); só os
   **refs** passavam crus. É o mesmo furo que `PatientsInClinic` fechou no agendamento.
2. **Derivação do relógio da clínica duplicada** (DRY D1, que a perf também tocou): o trio
   `load_clinic → tz → today` em `find_slots`, `who_fits` e a fronteira, com `candidates` lendo a
   clínica **duas vezes** por request.
3. **Índice de FK faltando** (perf): `availability_rules.clinic_id` era a única tabela nova sem um
   índice liderado por `clinic_id` — o "achado-h" do doc [26](26-auditoria-bate-volta-agenda.md)
   deixado aberto numa tabela.

## 4. O que foi corrigido

**(a) Segurança — validação de tenant nas refs da fila.** Teste vermelho primeiro
(`offer_convert_test.exs`: offer com prof de outra clínica; `waitlist_entry_test.exs`: enqueue com
paciente de outra clínica) — os dois nasceram vermelhos, provando o furo. Consertados com duas
validações no molde de `PatientsInClinic`:

- `Api.Scheduling.SlotHold.Validations.ProfessionalInClinic` (via `Api.Directory.professional_in_clinic?/2`);
- `Api.Waitlist.WaitlistEntry.Validations.PatientInClinic` (via `Api.Records.patients_outside_clinic/2`).

Ambos os lookups abrem a própria transação com a GUC (`with_clinic`), então funcionam sob RLS — o
`mix test` (BYPASSRLS) não pegaria um furo de GUC aqui. **Re-sonda:** os dois testes ficaram verdes
contra o banco real; suíte 643/0.

**(b) Performance — índice de FK.** `index [:clinic_id]` em `AvailabilityRule` + migration
`20260721132448_add_availability_rule_clinic_index`. **Re-sonda (EXPLAIN):**
```
SET enable_seqscan=off; EXPLAIN SELECT 1 FROM availability_rules WHERE clinic_id = '…';
 Index Only Scan using availability_rules_clinic_id_index   (era Seq Scan)
```

**(c) DRY D1 — `Api.Scheduling.clinic_now/1`.** Fonte única do relógio da clínica
(`%{timezone, today, now_minutes}`), consumida por `find_slots`, `who_fits` (com `clock` opcional
passado pela fronteira) e o `clock/1` do controller. O `candidates` deixou de reler a clínica.
Absorveu D6 (alias `LocalTime`). Refatoração pura — suíte 643/0 sem mudança de comportamento.

## 5. O que ficou para decisão humana (não corrigido)

- **Oban cron O(clínicas)/min** (perf, estrutural). LOW e defensível: `slot_holds` é efêmero (TTL 10
  min), então é seq scan de tabela quase vazia; a iteração por-clínica é imposta pela RLS. O custo é
  ser O(clínicas) transações/min **independente de carga** — negligível em 19 clínicas, revisitável
  em milhares (um único statement com conexão privilegiada, ou só as clínicas com holds). Não é bug.
- **`mint 1.9.1` — CVEs HIGH/MEDIUM** (memory-exhaustion / request-smuggling), pego pelo `mix
  hex.audit` que o toque no `mix.lock` disparou. **Não é deste diff** — `mint` é dep transitiva
  pré-existente, não entrou no lock da E5. Handoff para uma decisão de bump separada.
- **DRY D2–D5, D7** (plumbing byte-idêntico fila↔agenda: `finish`/`parseIds`, `/pacientes` gêmeo,
  boilerplate de socket, projeção de paciente, `same_clinic/2`). Reais, mas o projeto **clona por
  fatia de propósito**, e consertá-los toca arquivos já entregues (agenda). Baixo valor / risco em
  código shipado → candidatos a uma consolidação futura, não a este diff.
- **falta→quem-cabe (UI)**: o backend (`who_fits` + `/candidates`) está pronto e testado; o gatilho
  no drawer + o modal ficaram deferidos (doc 25 §9), como a trilha de auditoria separou "gravar" de
  "exibir".

## 6. Segunda passada — auditoria do diff dos consertos

Os consertos da primeira passada (as 2 validações, `clinic_now/1` + o refactor, a migration do
índice) e o **frontend de tempo real escrito à mão** (`connectWaitlist`, o `$effect` de conexão da
`/fila`, o `event.depends`) são **código novo que as caças não viram**. Segunda passada, focada
neles. **Nenhum achado novo** — parou na rodada 2, tudo REFUTADO/NÃO SE APLICA com sonda.

**As duas sondas que só a app rodando prova (o `mix test` não pode):**

- **Validações sob RLS não dão falso-positivo.** A preocupação: `ProfessionalInClinic`/
  `PatientInClinic` recusarem uma ref **legítima** da própria clínica porque o lookup leria sem a
  GUC sob RLS (o furo clássico invisível ao `mix test`/BYPASS). Sonda como `movimento_app`
  (NOBYPASSRLS, o role real do servidor):
  ```
  current_user real: [["movimento_app"]]
  ENQUEUE ok (PatientInClinic aceitou paciente legítimo sob RLS)
  OFFER   ok (ProfessionalInClinic aceitou prof legítimo sob RLS)
  CLEANUP ok
  ```
  Os helpers (`professional_in_clinic?/2` / `patients_outside_clinic/2`) abrem a própria transação
  com a GUC (`Api.Repo.with_clinic`), então funcionam sob RLS. Combinado com a 1ª passada provando
  que **recusam** ref alheia, as duas validações estão corretas nos dois sentidos. **REFUTADO** o
  falso-positivo.

- **O tempo real da `/fila` não faz churn** (o bug exato que a agenda teve: socket reconectando a
  cada `invalidate`, visível só no log). O `$effect` de conexão lê **só** `realtime` (um `$state`
  setado **uma vez** pelo fetch do token), nunca `data.*` — então `invalidate('fila:dados')`
  reexecuta o *load* mas não o efeito, e o socket não reconecta. Prova de leitura (a dependência
  reativa do effect) + log: `JOINED waitlist:<id>` aparece por **navegação**, sem re-joins dentro
  do ciclo de uma página. **REFUTADO** o churn.

**O resto do diff de conserto:** `clinic_now/1` é derivação pura (`load_clinic` global + `LocalTime`
puro, sem superfície de RLS); o refactor é preservador de comportamento (643 testes verdes, sem
mudança nos testes de `find_slots`/`who_fits`); a migration do índice foi re-sondada (`EXPLAIN` →
`Index Only Scan`); o `candidates` lê a clínica **uma vez** (o controller computa `clinic_now` e
passa o `clock` a `who_fits`, que não relê). Nada acende XSS/fronteira novos.

**Nota adversarial (NÃO SE APLICA como vuln):** `professional_in_clinic?/2` aceita profissional
**arquivado** da própria clínica, então dá para segurar um hold sobre um prof inativo. Inofensivo:
o hold é efêmero (10 min) e a **conversão** bate no `ReferencesActive` do agendamento (recusa prof
inativo) — o portão real é na criação do agendamento, não na reserva. Registrado, não corrigido.
