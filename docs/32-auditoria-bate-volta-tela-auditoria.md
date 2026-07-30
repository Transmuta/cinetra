# Bate-volta — tela de auditoria (`/configuracoes/auditoria`, F2 / doc 25 §11.4)

Auditoria da fatia que construiu a tela de auditoria: `read :audit_log` paginada nos recursos
`*.Version` (via `Api.Scheduling.TrailMixin`), `Api.Scheduling.list_audit_log/2` (feed + diff
encadeado + enriquecimento), `GET /api/audit` (`AuditController`, owner·admin) e a tela SvelteKit
(`+page`, `AuditEntry`, `FieldDiff`, link no `Sidebar`).

Contra a **stack rodando**: `psql` como `cinetra_app` (NOBYPASSRLS) e `postgres`
(`EXPLAIN ANALYZE`), `ConnCase` exercendo o pipeline real do `ApiWeb.Router` com sessão de magic
link, telemetria `[:api, :repo, :query]` contando queries. Três eixos caçados em paralelo
(segurança, performance, refatoração), cada achado provado por sonda antes de existir.

> **Escopo:** só esta fatia. A feature de **notificações** (`Api.Notifications`, doc 31),
> construída em paralelo, ficou de fora de propósito.

## 1. Onde parou, e por quê

Parou na **rodada 3 (conserto)**: as duas caças acharam 1 achado de segurança MÉDIO, 1
informativo, e 2 gargalos de performance reais mas estruturais. Consertados os de fronteira/DRY;
os estruturais viraram decisão humana (§5). A rodada 2 (adversarial) rendeu os dois gargalos de
performance que a checklist não tinha (o `COUNT(*)` da paginação e o filtro por autor sem índice)
— o ângulo "siga o fluxo e conte queries no volume real" pagou.

## 2. A varredura

| Eixo | Item | Estado | Sonda |
|---|---|---|---|
| **Seg** | Vazamento cross-tenant (feed, filtros, enriquecimento) | REFUTADO | 2 clínicas; owner A não vê nada de B em feed/record_id/user_id/attendance |
| **Seg** | Porta dos fundos da A7 no recurso de versão | REFUTADO | authorizer injetado; HTTP 403 (prof/recepção); página/interface crua vazias |
| **Seg** | `record_id`/`user_id` malformado → 500 | **CONFIRMADO** (MÉDIO) | `Plug.Exception.status` = 500 (Ecto.Query.CastError não tratado) |
| **Seg** | Injeção de átomo (`action=lixo`) | REFUTADO | whitelist barra antes do `to_existing_atom`; átomo não nasce; 200 |
| **Seg** | Autoridade server-side (não o menu) | REFUTADO | 401 sem sessão / 403 prof·recepção no `:4010`, independente do front |
| **Seg** | PII em log (obs/diff) | REFUTADO | nenhum `Logger`/`IO` no caminho da trilha |
| **Seg** | `created_by_id` (FK-uuid) cru no diff | **CONFIRMADO** (informativo) | surge `— → <uuid>`, fora do `@audit_diff_ignore` das outras FKs |
| **Perf** | Feed usa `(clinic_id, version_inserted_at DESC)`; `id DESC` força Sort caro? | REFUTADO | Incremental Sort sobre Index Scan; 0,07 ms flat a 52k linhas |
| **Perf** | `list_audit_log` é N+1? | REFUTADO | **5 queries constantes** (`= ANY`), não crescem com a página |
| **Perf** | `chain_diffs` usa `clinic_source_idx`; bounded? | REFUTADO | índice usado; 0,7 ms; bounded pelo histórico do registro |
| **Perf** | Janela `from/to` casa com o índice? | REFUTADO | igualdade+range no mesmo `Index Cond`; 0,10 ms |
| **Perf** | `COUNT(*)` da paginação (`countable`) | **CONFIRMADO** (estrutural) | O(linhas da clínica)/request: 0,45 ms→9,7 ms (2k→52k) |
| **Perf** | Filtro por autor (`user_id`) sem índice | **CONFIRMADO** (estrutural) | Seq Scan da clínica: 50k linhas / 6 ms |
| **Perf** | Offset profundo | CONFIRMADO (clampado 100k, fora do caminho) | full scan+sort em offset alto; UX empurra p/ filtro |
| **Ref** | `clamp_audit_*` clonam `records.ex` | CONFIRMADO (clone consciente) | mesma lógica + 3 constantes idênticas |
| **Ref** | `parse_int` gêmeo com guarda divergente + comentário falso | **CONFIRMADO** | `audit` aceitava negativo; comentário dizia "mesmo contrato" |
| **Ref** | `parsePage`/`pageLabel` idênticos a `patients.ts` | CONFIRMADO (clone consciente) | corpos byte-a-byte |
| **Ref** | `dayKey` duplica `zonedParts` + aloca formatter por chamada | **CONFIRMADO** | `new Intl.DateTimeFormat` por entrada, por render |
| **Ref** | Ash/Elixir/CLAUDE rules (query dinâmica, `!`, pattern match, `to_atom`, moduledocs) | REFUTADO | tudo compliant (ver §4) |

## 3. As causas-raiz

1. **Fronteira que deixa input cru chegar à camada de baixo.** `record_id`/`user_id` não-uuid
   passavam por `presence/1` (só "string não-vazia") e estouravam no filtro de coluna UUID → 500.
   Mesma classe que o arquivo já tratava para `from`/`to` (422) e `limit`/`offset` (default). É
   **uma** causa, não dois sintomas.
2. **Lista de ignore do diff incompleta.** `@audit_diff_ignore` esconde as FKs-uuid por design
   ("`<uuid> → <uuid>` não diz nada"), mas `created_by_id` ficou de fora.
3. **Custo O(linhas-da-clínica) por request na tabela que mais cresce** — duas faces: o
   `COUNT(*)` do `countable` (todo request) e o filtro por autor sem índice. **Estruturais**:
   a correção troca semântica de produto (perder o total "X de Z") ou custo de escrita (índice na
   tabela mais escrita). Não se resolve sozinho num patch — §5.
4. **Primitivas de paginação/params reclonadas por fatia.** Clone consciente (o próprio código
   cross-referencia), coerente com o D-U do doc 30. Só o `parse_int` tinha divergência real.

## 4. O que foi corrigido (por causa)

Ordem: segurança → refatoração barata. TDD, vermelho primeiro; re-sonda na rodada 5.

- **Causa 1 — 500 → 422 na fronteira.** `AuditController.build_opts/2` agora valida
  `record_id`/`user_id` com `Ecto.UUID.cast` (`parse_uuid/2`); malformado → 422, ausente → filtro
  nulo. `presence/1` saiu (só servia a esses dois).
  - Teste vermelho: `GET /api/audit?record_id=nao-e-uuid` e `?user_id=xxx` → 422 (antes: raise →
    500 no aggregate do `count`). Verde após o `Ecto.UUID.cast`.
  - Re-sonda: `mix test audit_controller_test` 13/13; o pipeline real do Router devolve 422.
- **Causa 2 — `created_by_id` no ignore.** Somado a `@audit_diff_ignore`.
  - Teste vermelho: `refute "created_by_id" in campos` (antes estava em
    `["created_by_id","encaixe","starts_at","status"]`). Verde após o ignore.
- **Causa 4 (parcial) — `parse_int`.** Guarda alinhada (`when n >= 0`) para o comentário "mesmo
  contrato de `PatientsController`" voltar a ser verdade; negativo → default, como pacientes.
- **Refatoração barata — `dayKey`.** Passou a reusar `zonedParts` (agenda.ts), fonte única do
  "dia local do instante", que já **cacheia** o `Intl.DateTimeFormat` por fuso — em vez de alocar
  um por entrada em `groupByDay`. Guarda de iso inválido preservada.
  - Re-sonda: `audit.test.ts` 20/20 (inclui os casos de virada de meia-noite por fuso);
    `svelte-check` sem erro nos arquivos da fatia.

Suítes pós-conserto: **backend 698/0**, **web 1093/0**; cobertura mantida (audit.ts 96%,
componentes/BFF/page ~100%; `audit_controller` 97%).

## 5. O que ficou para decisão humana

Nada de segurança em aberto (o CONFIRMADO MÉDIO foi corrigido; os demais refutados por sonda).
O que sobra é **estrutural** — a tabela de versão cresce para sempre e há um custo por-request
que acompanha esse crescimento:

- **P-A — `COUNT(*)` do `countable: true` é O(linhas-da-clínica) por request.** Conta a clínica
  inteira em toda carga de página, inclusive a página 1 (a página em si é 0,05 ms; o count é o
  custo dominante). Medido: **0,45 ms → 9,7 ms** de 2k para 52k linhas (~0,2 µs/linha → ~100 ms a
  500k, ~200 ms a 1M). **Por que não corrigi:** é decisão de **produto** — as saídas conhecidas
  (total estimado via `pg_class.reltuples`; `countable: false` + `limit+1` para o "more"; contar
  só quando há filtro) trocam o rótulo exato **"X–Y de Z"** por um aproximado ou o removem. Numa
  tela **owner·admin de baixo tráfego**, ~10–100 ms/carga é tolerável hoje. Simétrico em
  `attendances_versions`. **Correção quando doer:** decidir a semântica do total antes de mexer.
- **P-B — filtro por autor (`user_id`) faz Seq Scan da clínica.** Só há índice em
  `(clinic_id, version_source_id)` e `(clinic_id, version_inserted_at)`. Medido: **Seq Scan de 50k
  linhas / 6 ms** para achar 17 (~60 ms a 500k). **Por que não corrigi:** a **UI da v1 não expõe**
  o filtro por autor (é capacidade só de API/deep-link), e um índice
  `(clinic_id, user_id, version_inserted_at DESC)` adiciona **custo de escrita na tabela mais
  escrita do sistema** (uma linha por mutação de agendamento) para acelerar um filtro que nenhuma
  tela usa ainda. **Correção quando a tela expuser o filtro** (ou o volume crescer): criar o
  índice composto — serve o filtro **e** a ordenação por recência de uma vez. `filter_action`
  (`version_action_name`) é da mesma classe, porém menos grave (baixa cardinalidade); mesmo destino.
- **P-5 — offset profundo** faz full scan+sort (custo O(offset)). Já **clampado em 100k** e fora
  do caminho normal (a UX empurra para filtros). Baixa prioridade; vigiar.
- **DRY consciente (B1/F1/F2/B3)** — `clamp_audit_*` ↔ `records.ex`, `parsePage`/`pageLabel` ↔
  `patients.ts`, `presence` ↔ `blank_to_nil`. Clones que o próprio código cross-referencia;
  coerente com o "clona por fatia" do projeto (D-U, doc 30). **Correção quando reaparecer a 3ª
  cópia:** extrair `ApiWeb.Params` (`int/1`) no back + `$lib/pagination.ts`
  (`parsePage`/`pageLabel`) no front — um lote só, quando pagar. Não é dívida escondida: está aqui.

## 6. Provas-chave (coladas)

**RLS das tabelas de versão** (`cinetra_app`, NOBYPASSRLS, em transação com ROLLBACK):

```
sem GUC                       → appt 0 / att 0
GUC = clínica A               → appt 1 / att 1  (só A)
GUC = clínica B               → appt 1 / att 1  (só B)
```

**Feed no volume real** (52.017 linhas, plano fiel a produção com a GUC setada):

```
Limit  (rows=50)  Buffers: shared hit=5
  -> Incremental Sort  Sort Key: version_inserted_at DESC, id DESC
       Presorted Key: version_inserted_at
       -> Index Scan using appointments_versions_clinic_time_idx  (rows=51)
 Execution Time: 0.071 ms
```

**5 queries constantes** (uma chamada de `list_audit_log`, `resource: :appointment`):

```
#1 count(*) da paginação   #2 a página   #3 chain_diffs (= ANY)
#4 users (= ANY)           #5 professionals (= ANY)
```

**O 500 corrigido** (antes do conserto): `?record_id=nao-e-uuid` →
`Ecto.Query.CastError … "nao-e-uuid" … cannot be cast to type UUIDv7` → `Plug.Exception.status = 500`.
Depois: **422**.

## 7. Verificação do diff dos consertos (rodada 5 sobre o código novo)

O código do conserto (`parse_uuid`, o ignore atualizado, `dayKey`, `parse_int`) nasceu **depois**
das caças — logo é superfície não-auditada. Passado pelas listas + sonda, virou **regressão
permanente** (não teste-e-joga-fora):

- **`parse_uuid` — fronteira reabrida.** Malformado → 422 (não 500); ausente/vazio → filtro nulo;
  **devolve o valor original** (não o normalizado do `Ecto.UUID.cast`) — provado seguro: o
  Postgres compara uuid **case-insensitive** (`'019F…'::uuid = '019f…'::uuid` → `t`), então um
  `record_id` em maiúsculas ainda casa.
- **`count: true` sob filtro** — o total tem que ser o do RECORTE, não da clínica: sem filtro
  `total == 4`, com `record_id` `total == 3`. (Guarda contra o "X de Z" mentir sob filtro.)
- **Offset hostil** — `?offset=999999999999` é **clampado (100k) → 200 vazio**, não estoura o
  int64 no Postgrex (mesma classe do 500 de uuid, agora fechada dos dois lados).
- **Janela invertida** — `to < from` → **422** (`parse_window`, a regra da agenda).
- **FK-uuid no diff de attendance** — `patient_id`/`appointment_id` **não** aparecem (o
  `@audit_diff_ignore` vale para os dois recursos, simétrico ao `created_by_id`).
- **`dayKey` (reuso de `zonedParts`)** — `svelte-check` sem erro nos arquivos da fatia; os casos
  de virada de meia-noite por fuso seguem verdes.

Nenhum achado novo. Suítes pós-verificação: **backend 706/0**, **web 1093/0**; `svelte-check`
limpo na fatia. A rodada 5 **não** consertou nada (não havia o que) — só provou o conserto na app
rodando e auditou o diff dele.
