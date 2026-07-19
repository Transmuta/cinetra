# 26 — Auditoria bate-volta: fatia Agenda

Auditoria em 5 rodadas da Entrega 1 da agenda ([25](25-agenda.md)), commits
`f5b455e..8d1d6a6`, contra a **stack rodando**: `psql` como `movimento_app` (NOBYPASSRLS),
`mix test`, `curl` concorrente na API, `mix run` com membership real, e Playwright no
navegador. Nenhum achado entrou aqui sem output de sonda.

**Onde parou:** rodada 5, com consertos aplicados e re-sondados. As rodadas de caça acharam
**16 confirmados**; a consolidação os agrupou em **6 causas-raiz**; 11 foram corrigidos e 5
ficam para decisão humana (§5).

## 1. A varredura

| Eixo | Item | Estado | Sonda |
| --- | --- | --- | --- |
| **Seg** | Bypass do BFF / ataque direto | REFUTADO | `curl` sem cookie nas 3 rotas → 401·401·401 |
| **Seg** | Tenant vindo do cliente | REFUTADO | `whitelist/2` — `clinic_id` e `ends_at` fora da lista |
| **Seg** | IDOR / BOLA | REFUTADO | policy → `NotFound`; RLS → 0 linhas sem GUC / de outra clínica |
| **Seg** | Function-level authz | **CONFIRMADO ×3** | A9 ausente · coluna do colega · trilha sem authorizer |
| **Seg** | Mass assignment | **CONFIRMADO** | `encaixe` aceito de qualquer papel |
| **Seg** | Cross-tenant em relação | **CONFIRMADO** | `patient_ids` de outra clínica → CRIOU |
| **Seg** | XSS · SQLi · SSRF · open redirect · path traversal | REFUTADO / N/A | `grep '{@html'` → 0; SQL cru só DDL; caminhos literais |
| **Seg** | CORS / CSRF | REFUTADO | `HttpOnly; SameSite=Lax`, sem `ACAO` |
| **Seg** | Vazamento de `clinic_id` | REFUTADO | os 4 serializers omitem |
| **Seg** | Dependência vulnerável | REFUTADO p/ este diff | 4 advisories, todas pré-existentes (`mint`, `phoenix_live_view`) |
| **Perf** | N+1 por linha | REFUTADO | `load` emite `= ANY(array)`, não 1/linha |
| **Perf** | Seq scan no `:in_range` | REFUTADO | Index Scan nos dois índices; RLS vira One-Time Filter |
| **Perf** | Índice redundante | REFUTADO (os 2 principais) | `pg_stat_user_indexes`: 14 e 8 scans |
| **Perf** | Waterfall de fetch | **CONFIRMADO** | 22 queries/dia, 254/30 dias, com sonda duplicada |
| **Perf** | Query repetida | **CONFIRMADO** | 5× `memberships` idênticas por request |
| **Perf** | Índice de FK faltando | **CONFIRMADO** | `appointment_type_id`, `created_by_id` → seq scan |
| **Perf** | Crescimento sem poda | **CONFIRMADO** | zero retenção nas tabelas de versão |
| **DRY** | Code interface (ash.md) | **CONFIRMADO** | teste lia a trilha com `Ash.read!` cru (não havia `define`) |
| **DRY** | Duplicação na fronteira | **CONFIRMADO** | `diff` dos helpers: 27 linhas, 2 divergem só na mensagem |
| **DRY** | `in_clinic` reescrito à mão | **CONFIRMADO** | 2 cópias novas; moduledoc contradiz o código |
| **DRY** | Mesma regra em 2 lugares | **CONFIRMADO** | `layoutAppts` ignora cancelado · `t2m` 3ª cópia (NaN vs 0) |
| **DRY** | Componente reimplementado | **CONFIRMADO** | `Field.svelte` 6× — cópia já divergiu (10px, tokens) |
| **DRY** | Elixir idiomático | REFUTADO | `with` de precedência, multi-cláusula por átomo: corretos |
| **Web** | `any` / fronteira server-client | REFUTADO | `npm run check` 0 erros; único fetch vai ao próprio BFF |

**O que a rodada 2 (adversarial) achou que a 1 não tinha achado:** o mais importante de toda a
auditoria — que **o diagnóstico registrado nos commits estava errado** (§3, causa C) — e o
teste de **corrida real** na exclusion constraint, que a checklist não pedia.

## 2. As causas-raiz

| # | Causa | Achados que ela explica |
| --- | --- | --- |
| **A** | O recorte A7/A9 vivia **só na leitura do `Appointment`** | encaixe sem policy · coluna do colega · `Attendance` sem recorte · trilha sem authorizer |
| **B** | Pertinência ao tenant validada **por acaso** | `patient_ids` cross-tenant (prof/tipo só barram porque um lookup existia por outro motivo) |
| **C** | Comentários e doc afirmam **causa e detector falsos** | "RLS barrou a leitura" · "changes não falam com o Repo" · "só morde no servidor real" |
| **D** | Duplicação na fronteira HTTP | 27 linhas nos controllers · 5 fontes do 422 em 2 formatos · `with_scheduling_scope`≡`with_member_scope` |
| **E** | Mesma regra em dois lugares, já divergentes | `layoutAppts` × `conflictIds` · `t2m` × `timeToMinutes` · `Field` × cópias |
| **F** | Leitura que recarrega o que já tinha | sonda duplicada no `/availability` · fan-out por profissional · 5× `memberships` |

## 3. O que foi corrigido

### Causa A — uma peça compartilhada por face, não quatro remendos

| Achado | Sonda que achou | Conserto | Re-sonda |
| --- | --- | --- | --- |
| **A9 nunca implementada**: `profissional` cria `encaixe: true` — e `encaixe` é o predicado que **isenta da exclusion constraint**, ou seja, o papel menos privilegiado desligava a proteção contra dupla-marcação | `mix run` com membership real → `!!! PROFISSIONAL CRIOU ENCAIXE: encaixe=true` | `Checks.CreatingEncaixe` + policy condicional; lê o **argumento** (o atributo só existe depois do change) | `403 Forbidden OK` |
| **Agenda do colega**: profissional escrevia em coluna que não consegue ler | `mix run` → `!!! PROFISSIONAL AGENDOU NA AGENDA DO COLEGA` | `Checks.OwnProfessionalColumn`, fail-closed no `professional_id: nil` | `403 Forbidden OK` |
| **`Attendance` sem A7**: `list_appointments` devolvia 0 e `list_attendances` devolvia a clínica inteira | `mix run`, papel profissional → 3 pares (appointment_id, patient_id) vazados | `OwnAgendaOnly` **movido para o domínio** e parametrizado (`via: :appointment`) | 4 de 5 na clínica — exatamente os do próprio profissional |
| **Trilha sem authorizer**: `*.Version` nasce sem `Ash.Policy.Authorizer`, o que torna `authorize?: true` um no-op | `Ash.read!(Appointment.Version, authorize?: true)` como profissional → 3 versões da clínica | `TrailPolicies` via `version_extensions` + `mixin` (opções do próprio DSL, sem gambiarra): ler é owner·admin, escrever é ninguém | **0 versões** |

### Causa B

`patient_ids` de outra clínica era aceito e gravava `Attendance` com `clinic_id` de A e
`patient_id` de B. Corrigido com `Records.patients_outside_clinic/2` + validação —
**sem ecoar os ids recusados**, porque confirmar "existe, mas não é seu" é o oráculo que o
isolamento não deve dar.

### Causa C — a correção mais importante, e é contra o próprio autor

Os commits e o doc afirmavam que três bugs vistos ao vivo eram *"leitura sem GUC barrada pela
RLS"*. **Falso**, provado por três sondas:

- `docker-compose.yml:34` → `DATABASE_USER: postgres`: o app **em dev bypassa RLS**;
- `Api.Repo.on_transaction_begin/1` **já injeta a GUC** em toda transação de leitura com tenant;
- restaurar o código antigo num experimento controlado devolveu o resultado correto, inclusive
  o 422 de expediente.

Corrigido em [25 §9](25-agenda.md) e na memória do projeto. A lição verdadeira é pior que a
registrada antes: **não existe hoje nenhum caminho de execução local que detecte GUC ausente** —
nem `mix test` (sandbox `postgres`), nem o navegador em dev. Só produção. Ver §5.

### Causa E (web)

`layoutAppts` não conhecia `cancelado`: um bloco cancelado alargava a coluna para 304px sem o
aviso de conflito acender. A regra ganhou dono único (`ocupaGrade`) e a alocação separou duas
perguntas que estavam confladas: **`lanes`** (fração da coluna — fantasmas participam, senão o
cancelado renderiza por cima do vivo) e **`maxLanes`** (largura — fantasmas excluídos).
Verificado **no navegador**: cancelado riscado, sem borda vermelha, coluna na largura normal,
contador de 2 → 1.

Também: `timeToMinutes` unificado (3 cópias divergindo **NaN vs 0** — e `0` é meia-noite, um
valor válido, então o erro entrava como posição errada e nunca como exceção) e `Field.svelte`
nos inputs da agenda.

### Números finais

| | Antes | Depois |
| --- | --- | --- |
| Backend | 463 testes · 89,4% | **481 testes · 89,6%** |
| Web | 747 testes · 92,9% | **764 testes · 93,0%** |
| `svelte-check` | 0 erros | 0 erros |
| Corrida real (6 POSTs paralelos) | 1×201, 5×422, 0×500 | **idem** (sem regressão) |

## 4. Provas que valem guardar

**A exclusion constraint segura concorrência de verdade** — critério do [25 §7](25-agenda.md)
que não havia sido testado:

```
6 POSTs paralelos no mesmo slot  →  1 × 201   5 × 422 schedule_conflict   0 × 500
```

**A RLS isola as tabelas de versão** (contrariando uma ressalva do próprio conserto):

```
movimento_app, sem GUC   → appt_versions=0  att_versions=0
movimento_app, com GUC   → appt_versions=5
```

**O custo da RLS no plano é nulo** — a policy vira `One-Time Filter`, avaliada uma vez:

```
Result  (cost=0.15..8.17 rows=1)
  One-Time Filter: ((current_setting('movimento.clinic_id', true))::uuid = '019f7c5b-...'::uuid)
```

## 5. O que ficou para decisão humana

### 5.1 Estrutural

**(a) Nenhum ambiente exercita a RLS.** Dev e teste conectam como `postgres` (BYPASSRLS); só
`compose.prod.yml` usa `movimento_app`. Vários moduledocs dizem "só morde no servidor real",
como se houvesse detector — não há. **Correção:** apontar o container de dev para
`movimento_app`, **ou** um job de CI com role NOBYPASSRLS. Não aplicado: muda ambiente, e a
escolha entre os dois é sua.

**(b) A autoridade do recorte ficou em dois lugares.** O conserto de escrita
(`OwnProfessionalColumn`) lê do **`Membership`** e documenta que o `Api.Scope` é só
informativo; a leitura (`OwnAgendaOnly`) continua lendo do **`Api.Scope`**. Via HTTP são
consistentes (o `LoadScope` deriva o escopo da membership), então **não é vulnerabilidade
hoje** — é a assimetria que vira uma. Achado da rodada 5, sobre código escrito na rodada 3.

**(c) A trilha torna o agendamento indeletável.** Descoberto ao limpar o banco:

```
ERROR: update or delete on table "appointments" violates foreign key constraint
       "appointments_versions_version_source_id_fkey"
```

Sem `ON DELETE` na FK do AshPaperTrail, apagar um agendamento exige apagar as versões antes.
Não morde nesta fatia (não há destroy, por decisão), mas **é o mecanismo concreto pelo qual um
pedido de exclusão LGPD não se resolve com um `DELETE`**.

### 5.2 Produto / compliance

**(d) `obs` é retido para sempre na trilha.** `store_action_inputs? false` está valendo, mas
impede só a *segunda* cópia — o `changes` grava o valor. Sonda: `obs NA TRILHA -> "HIV+, usa
cadeira de rodas"`. Combinado com (c), a retenção é ilimitada e o apagamento é manual. Opções:
`ignore_attributes [:obs]` (perde o histórico do campo), redação na trilha, ou política de
expurgo. **É a pendência que o [25 §11.3](25-agenda.md) já previa, agora com prova.**

**(e) Duas regras do [25 §7](25-agenda.md) nunca foram implementadas** — e a auditoria
confirma que não é bug, é escopo não feito: **"Turma ≤ capacidade"** (A-D3, `422 group_full` —
`grep group_full lib/` → zero) e **"Tipo arquivado / profissional ou paciente inativo → 422"**.
O merge idempotente de turma (A-D4) também não existe. Decida se entram na Entrega 1 ou viram
fatia própria.

### 5.3 Performance (medido, não aplicado)

**(f) `/api/availability`: 254 queries para 30 dias**, com uma **sonda duplicada gratuita** —
`render_days/3` carrega as fontes só para validar que o profissional existe e as descarta, e
`day/4` recarrega. Somado ao fan-out (1 request por profissional) e ao duplo `carregarDia` da
janela noturna: **até 480 queries por render de dia com 10 profissionais**. Correções em ordem
de retorno: (1) remover a sonda duplicada — trivial; (2) carregar as fontes uma vez para a
janela (`data in ^datas`) → ~6 queries para 30 dias; (3) aceitar `professional_id` múltiplo,
matando o fan-out; (4) devolver o `timezone` no `/auth/me`, matando o duplo carregamento.

**(g) 5 queries idênticas de `memberships` por request** — `HasClinicRole` reconsulta a cada
avaliação de policy. Não cresce com linhas, cresce com nº de leituras (e os checks novos
somaram mais). Correção: memoizar por request; o `Api.Scope` já carrega `papel`.

**(h) 2 FKs sem índice** (`appointment_type_id`, `created_by_id`) → seq scan em `appointments`
no `DELETE` do alvo. Atenuado porque tipos e profissionais **arquivam** em vez de excluir; mas
`users` não tem essa proteção.

**(i) `pool_size: 10` vs o fan-out** — 10 profissionais saturam o pool num único render. Não
medido sob carga.

### 5.4 Não medido, por falta de volume

Com 2 agendamentos, o planner acerta por sorte. Ficaram em aberto: se
`attendances_clinic_id_appointment_id_index` é morto ou só adormecido, o custo do check da
exclusion constraint por INSERT, e o comportamento do pool. Semear ~1.800 linhas resolveria —
**não foi feito para não escrever no banco de dev sem sua autorização.**

## 6. Nota de conduta

Um subagente, ao limpar uma sonda, rodou `DELETE FROM attendances_versions WHERE clinic_id=<demo>`
sem qualificar por `version_source_id` e **apagou 2 linhas de trilha pré-existentes** da clínica
demo. Os agendamentos e attendances estão intactos. É dado de demonstração, sem valor — mas fica
registrado, porque trilha apagada por engano é exatamente o que a fatia existe para impedir.
