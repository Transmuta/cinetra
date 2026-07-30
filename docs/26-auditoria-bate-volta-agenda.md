# 26 — Auditoria bate-volta: fatia Agenda

Auditoria em 5 rodadas da Entrega 1 da agenda ([25](25-agenda.md)), commits
`f5b455e..8d1d6a6`, contra a **stack rodando**: `psql` como `cinetra_app` (NOBYPASSRLS),
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

### Causa C — RETRATADA: a auditoria errou, o diagnóstico original estava certo

**Esta seção afirmava o oposto e foi corrigida.** Fica registrada como está porque o erro de
método vale mais que a conclusão.

A auditoria concluiu que o diagnóstico dos commits (*"três bugs = leitura sem GUC barrada pela
RLS"*) era falso, com base em: `docker-compose.yml` define `DATABASE_USER: postgres`, logo o
app bypassa RLS em dev; e um experimento controlado onde o código antigo funcionava.

**As duas premissas estavam erradas, pela mesma razão.** `docker compose exec` **não passa pelo
entrypoint**, e o `entrypoint.dev.sh` termina com:

```bash
exec env DATABASE_USER="${APP_USER}" DATABASE_PASSWORD="${APP_PASS}" mix phx.server
```

O `DATABASE_USER: postgres` do compose é o usuário **privilegiado, para migrations/DDL**; o
servidor sobe como `cinetra_app`. Todas as sondas feitas por `exec` — as minhas e as de dois
subagentes — mediram um ambiente que não serve requisição nenhuma.

`pg_stat_activity` desfaz a dúvida em uma linha:

```
    usename    | conexoes
---------------+----------
 cinetra_app |       10     ← o servidor
 postgres      |        1     ← o psql da própria sonda
```

E o experimento decisivo, a mesma chamada sob os dois roles:

```
### como cinetra_app (o role do servidor real) ###
SEM in_clinic/with_clinic : 0 profissionais
COM in_clinic/with_clinic : 2 profissionais

### como postgres (o que mix test e as sondas ruins usavam) ###
SEM in_clinic : 2 profissionais
```

**Conclusão correta:** o diagnóstico original estava certo, os `in_clinic`/`with_clinic` são o
conserto, e `Api.Repo.on_transaction_begin/1` **não cobre** leitura crua por-tenant apesar do
que promete o próprio moduledoc.

**Lição de método, que é o que esta seção passa a documentar:** ao sondar comportamento
dependente de role ou ambiente, **verifique quem a sonda é** (`SELECT current_user`) antes de
acreditar nela, e observe o processo real (`pg_stat_activity`) em vez de inferir do arquivo de
configuração. Três medições independentes erraram igual porque todas herdaram a mesma suposição
não checada. Para sondar como o servidor:

```bash
docker compose exec -e DATABASE_USER=cinetra_app -e DATABASE_PASSWORD=cinetra_app api ...
```

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
cinetra_app, sem GUC   → appt_versions=0  att_versions=0
cinetra_app, com GUC   → appt_versions=5
```

**O custo da RLS no plano é nulo** — a policy vira `One-Time Filter`, avaliada uma vez:

```
Result  (cost=0.15..8.17 rows=1)
  One-Time Filter: ((current_setting('cinetra.clinic_id', true))::uuid = '019f7c5b-...'::uuid)
```

## 5. O que ficou para decisão humana

### 5.1 Estrutural

**(a) `mix test` não exercita a RLS** — a suíte conecta como `postgres` (BYPASSRLS), então um
bug de GUC ausente passa verde. **Dev exercita** (o servidor sobe como `cinetra_app`), o que
faz de "rodar a tela" um detector real — e foi ele que pegou os três bugs da construção.
**Correção pendente:** uma parte da suíte rodando como `cinetra_app`, para que o gate do CI
também pegue. Não aplicado: mexe no sandbox do Ecto e é decisão de infra.

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

## 7. Liquidação das pendências (2026-07-20)

Fechamento da §5 inteira, numa passada só. O que segue é o que **mudou**, com a medida ao lado —
nenhum item aqui é "revisei e está ok".

### 7.1 Segurança e autoridade

**(b) A autoridade do recorte voltou a ser uma só.** Nasceu
[`Api.Accounts.ActiveMembership`](../api/lib/api/accounts/active_membership.ex), por onde passam
agora os três consumidores: `HasClinicRole` (policies), `OwnProfessionalColumn` (escrita) e
`OwnAgendaOnly` (leitura). Ele reusa a membership que o `Api.Scope` já carregou, mas **só quando
ela confere** com o actor e o tenant da ação, está `:ativo` e veio do banco
(`__meta__.state == :loaded`).

Essa quarta condição não é decorativa: sem ela, um chamador interno que montasse
`Scope.with_membership(user, %Membership{papel: :owner, ...})` com o próprio `user_id` e o
próprio `clinic_id` passaria pelas outras três — ele escolhe os campos que seriam conferidos.
Exigir `:loaded` transforma "confere consigo mesma" em "existe no banco". Tem teste dedicado
(`membership forjada com papel inflado NÃO passa`).

**Um fail-open apareceu no caminho — e não estava no relatório original.** Ao medir a requisição
real (não a suíte), a sonda mostrou o `OwnAgendaOnly` rodando **duas** vezes por leitura da
agenda, e na segunda com `context == %{private: ..., shared: ...}`: **sem escopo**. A query de
`load:` de relacionamento — o `load: [:attendances]` — não herda o contexto da query de cima, só
a chave `:shared`. Lendo o `Api.Scope` direto do contexto, a preparation recebia `nil` e
devolvia "sem papel", ou seja, **não filtrava nada**, dentro do módulo cujo moduledoc existe
para evitar fail-open.

Não vazou: as `attendances` carregadas já vinham penduradas em `Appointment`s recortados pelo
filtro do pai. Mas a garantia A7 dependia disso, e não da regra. Corrigido nos dois eixos — o
escopo passou a viajar também em `:shared` (`Api.Scope.get_context/1`), e a resolução tem o
banco como rede quando nem isso chega.

> **Lição de método, de novo a mesma:** a suíte estava verde e continuou verde. O defeito só
> existia na forma como o Ash monta a query de `load:`, que nenhum teste de comportamento
> distinguia — porque o filtro do pai mascarava o do filho. Foi a **contagem de queries numa
> requisição real** que o expôs, medindo uma coisa (performance) e achando outra (autorização).

### 7.2 Performance — medido antes e depois

| Achado | Antes | Depois | Prova |
| --- | --- | --- | --- |
| **(f)** `/api/availability` | 254 queries / 30 dias, × fan-out de 1 requisição por coluna (~480 para 10 profissionais) | **14 queries, constante** — 1 dia × 1 prof e 30 dias × 2 profs custam o mesmo | teste `o custo não cresce com a janela nem com o nº de profissionais` |
| **(g)** `memberships` por request | 5 SELECTs idênticos | **1** (só o do `LoadScope`) | teste `a membership é resolvida uma vez por request` + medição ao vivo |
| **(f)(4)** duplo `carregarDia` | 2 round-trips na janela noturna | **1, sempre** | teste `sem ?date=, acerta o dia da clínica na PRIMEIRA busca` |

Como: `load_availability_window/4` carrega as quatro fontes **uma vez para a janela inteira** (o
motor `Availability` já é puro e recorta por data, então entregar a janela não muda veredito
nenhum); a sonda duplicada de `render_days/3` — que carregava as fontes só para validar que o
profissional existe e as descartava — deixou de existir; o endpoint passou a aceitar vários
`professional_id`; e `timezone`/`agora` viajam no `/auth/me`, então o BFF sabe que dia é na
clínica **antes** da primeira busca (sai da membership já carregada: zero leitura a mais).

**(i) `pool_size`** fica em 10 (env `POOL_SIZE`). O mecanismo que a §5 descrevia — 10
profissionais saturando o pool num render — **deixou de existir com o fim do fan-out**: o dia
agora são duas requisições sequenciais. Mexer no número sem carga real seria trocar um palpite
por outro.

### 7.3 Banco

**(h) Índices nas duas FKs.** `appointments_appointment_type_id_index` e
`appointments_created_by_id_index`. O detalhe que quase virou um índice inútil: sem
`all_tenants? true`, o ADR-017 prefixa `clinic_id`, e um índice `(clinic_id, X)` **não serve** a
`WHERE X = $1` — que é a forma exata da checagem de FK, feita pelo Postgres sem nenhuma noção de
tenant. O índice sairia na migração e o seq scan continuaria.

**(c) A trilha deixou de tornar o registro indeletável.** `reference_source? false` nos dois
recursos — é a saída que o próprio AshPaperTrail documenta para *"allowing actual deletion of
data"*. Escolhida em vez de `on_delete: :delete` porque **preserva o histórico**: a versão
sobrevive órfã em vez de ser levada junto. Trilha que some quando o registro some não é trilha —
e a §6 acima registra um apagamento acidental de versões justamente para não repetir isso.

Provado no banco, em transação revertida:

```
versoes_antes = 1  →  DELETE 1 (attendances) · DELETE 1 (appointments)  →  versoes_sobreviventes = 1
```

Antes, o mesmo `DELETE` estourava
`violates foreign key constraint "appointments_versions_version_source_id_fkey"`.

### 7.4 Produto

**(d) `obs` continua retido na trilha, por decisão** — registrada como A-D13 em
[25 §11.3](25-agenda.md). É campo operacional do agendamento ("trazer exame", "chega 10min
antes"), não prontuário; proteger por precaução custaria o histórico do campo para blindar um
conteúdo que raramente é sensível. Continua sob as policies da trilha (ler é owner·admin).
Segue em aberto, e é outra pergunta: **prazo de retenção da trilha como um todo**.

**(e) e (a)** já haviam sido fechados em `d5cbfea` (capacidade de turma, validações de ativo, e
o job `api-rls` no CI).

### 7.5 Estado ao fim da passada

Backend **531 testes / 90,0%** · Web **771 testes / 93,0%** · gate RLS **7/7 como
`cinetra_app`** · endpoints verificados ao vivo sob o role restrito, com 2 profissionais × 3
dias devolvendo períodos reais. (Números após o bate-volta da §8.)

Um desvio honesto de medição, registrado porque quase virou falso positivo: a primeira sonda ao
vivo devolveu `closed_reason: "clinica_fechada"` numa segunda-feira — a assinatura exata do bug
de RLS que esta fatia já levou três vezes. Não era: a clínica em questão (`Zona Sul`) não tem
**nenhuma** linha em `clinic_hours`. Conferido no banco antes de concluir qualquer coisa, e a
verificação foi refeita numa clínica com expediente cadastrado.

## 8. Bate-volta da §7 (2026-07-20)

A §7 foi ela própria auditada — três eixos em paralelo (segurança, performance, refatoração),
cada achado provado contra a stack rodando. **Segurança: zero achados** em 22 itens de checklist
e 6 perguntas dirigidas. Performance e refatoração acharam 12, dos quais os dois abaixo eram os
que mais importavam.

### 8.1 O CI quebraria

`mix format --check-formatted` estava **vermelho** em quatro arquivos da §7 — e é passo do job
`api` (`ci.yml:60`). A §7 foi declarada pronta tendo rodado suíte, cobertura, gate de RLS e
verificação ao vivo, e **não** o formatador. Vale registrar o modo de falha: rodar as sondas
difíceis não substitui rodar as fáceis.

### 8.2 A correção de (f)(4) cobrou um preço que ela não anunciava

Para matar o segundo round-trip da janela noturna, o load da agenda passou a fazer
`await event.parent()` antes de qualquer busca. Loads de servidor do SvelteKit rodam em
paralelo; `parent()` os põe em fila. Medido no log da API:

```
03:38:36.794Z  GET /api/auth/me
03:38:36.835Z  GET /api/appointments     (+41ms — só começa depois do /me)
03:38:36.883Z  GET /api/availability
```

Trocou-se um round-trip **condicional** (só na janela noturna, só sem `?date=`) por um
**incondicional**, em 100% das cargas — inclusive em cada clique nas setas de dia, onde o fuso
não decide nada porque a data veio na URL.

**Corrigido**, e a correção descobriu que a premissa estava errada: o que faltava para saber o
dia da clínica antes da busca era o **fuso**, não o relógio — o relógio é o do nosso próprio
servidor. Então `parent()` só é esperado quando não há `?date=`, e `agora` **saiu** do
`/auth/me`.

Sair foi o segundo ganho. O `/me` é carregado pelo layout, que o SvelteKit não reexecuta em
navegação client-side (`goto`) — um instante vindo dali congelaria na abertura da aba, e uma
aba atravessando a meia-noite passaria a marcar "Hoje" no dia errado. A mesma classe de bug
que a janela noturna já custou uma vez. O `today` da tela voltou a sair do relógio que vem
**na resposta** da API. (Não foi provado por sonda: o Playwright MCP estava quebrado na sessão
e não deu para exercitar navegação client-side. Corrigido por construção, não por medição.)

### 8.3 Índices duplicados

A migração criava `(clinic_id, version_source_id)` nas duas tabelas de versão — **byte a byte
iguais** aos que `20260719200000` já criara à mão, com outro nome. Custo de escrita em dobro em
tabelas que crescem a cada update. O `up` passou a derrubar os escritos à mão; ficou o derivado,
que se mantém sozinho nos codegens futuros. Num banco criado do zero, agora sai **um por tabela**.

Nenhum dos dois é usado hoje (`idx_scan = 0`, e `grep version_source_id lib/` não acha
consumidor) — quem os justifica é a tela `/configuracoes/auditoria` do [25 §11.4](25-agenda.md),
que lê o histórico *de um registro*.

### 8.4 A duplicação que era a §7 repetindo o próprio erro

`window_sources` (leitura, por-janela) e `sources_for` (escrita, por-dia) faziam as mesmas
quatro leituras com o mesmo mapa de saída, divergindo só no operador do filtro (`== ^date` ×
`in ^dates`). E os donos são **lados opostos**: a agenda usa a primeira, o `CheckAvailability`
— que valida expediente ao agendar — usa a segunda. Uma quinta fonte de disponibilidade
entraria num lado só, e a tela passaria a discordar do validador de escrita sobre o que é
expediente. Que é o achado **(b)**, o mesmo que a §7 acabara de consertar em outro lugar.

Unificado em `gather_sources/3`: `in ^lista` cobre `== ^valor` com lista de um, então a forma
de janela é a geral e a de dia é o caso particular. O gate de RLS cobre o caminho de escrita e
ficou verde.

### 8.5 Duas correções da §7 que a auditoria mediu como menores do que foram descritas

Registradas porque descrição inflada envelhece pior que achado pequeno.

**O `:shared` não é o que fecha o fail-open.** A §7.1 dá a entender que sim. Sondado por
mutação: removendo a propagação, a suíte continua **verde** — quem garante o recorte é o
fallback ao banco em `ActiveMembership`. O `:shared` é a economia de query do achado (g).
Tirar deixa o sistema correto e mais lento. Os comentários no código foram corrigidos, e agora
há teste para os dois caminhos.

**O fail-open do `load:` não era explorável, e nenhum teste de comportamento o pega.** Tentou-se
escrever um: revertendo o `OwnAgendaOnly` ao código original, o teste **passa igual**. A razão é
estrutural — as `attendances` chegam sempre penduradas em `Appointment`s que o filtro do pai já
recortou, então não há entrada pela qual a falta do filtro aninhado se manifeste. O que se
corrigiu, então, não é um vazamento: é a garantia deixar de ser **acidental** (consequência do
pai) e passar a ser **regra** (do filho). Continua valendo a pena; só não é o que a §7 sugeria.

**E o `active_timezone` não tinha bug vivo.** O `Enum.find_value` de fato escorregaria para o
fuso de outra clínica se a ativa não tivesse `timezone` resolvível — mas `timezone` é
`allow_nil? false` e a read `active_for_user` sempre carrega `:clinic`, então a precondição não
ocorre. Trocado por `Enum.find` + casamento assim mesmo (a forma que não *pode* escorregar), e
ganhou o teste de duas clínicas que faltava.

### 8.6 O que ficou para decisão humana

**Retenção da trilha órfã.** Com `reference_source? false`, some o último mecanismo que ligava
versão a origem: nada no código lê `version_source_id`, nada apaga versão, e o cascade que
podaria a trilha junto com o pai deixou de existir. É o outro lado do acordo de A-D13 — não
existe hoje política de expurgo nem consumidor que justifique guardar. Decisão de negócio, não
descuido.

**Duas anotações de conduta.** Um subagente, sondando se o `/auth/me` vazava clínica sem
vínculo, logou por magic link como `bruno.recepcao@example.com` — e esse fluxo **aceita o
convite pendente**: a membership dele em "Clínica Fidelidade" passou de `pendente` para
`ativo`. Foi via HTTP, não escrita direta, mas mudou estado sem avisar. E a validação da
migração exigiu dropar o banco de **teste**, o que derrubou os grants do role `cinetra_app` e
fez o gate de RLS falhar em 6 de 7 até o `setup_app_role.sql` ser reaplicado — falha de
ambiente, não de código, mas que por um momento pareceu regressão.
