# 24 — Auditoria bate-volta: fatia Pacientes

Auditoria em rodadas da fatia **Pacientes** (backend `Api.Records` + frontend `/pacientes`),
contra a stack rodando. Método do `.claude/skills/bate-volta`: caça (rodadas 1–2, três eixos
delegados a subagentes em paralelo, cada achado provado por sonda), consolidação, conserto
(rodada 3), verificação (rodada 5). **Nenhum achado existe sem output de sonda.**

## 1. Onde parou, e por quê

Parou na **rodada 3** (conserto). As duas caças fecharam com **0 bug de segurança e 0 de
performance**; o eixo de refatoração achou duplicação real de baixo risco. Consertei os itens
**dentro do diff da fatia** (DRY + 1 comentário + 1 teste), re-sondei tudo verde na rodada 5, e
mandei para decisão humana o que **escorrega para código vizinho** (Directory/Scheduling) ou é
**deferimento acoplado à paginação**.

## 2. A varredura

Alvo delimitado (`git status`): backend novo (`Api.Records` domínio+recurso+enum,
`PatientsController`, migrations `add_patients` + `patients_rls`, testes), edits em `router.ex`
e `config.exs`; frontend novo (`patients.ts`/`server/patients.ts`, `PatientForm.svelte`, rotas
`(app)/pacientes/**`), edits em `Sidebar.svelte` e `masks.ts`. (O `favicon.svg` do working
tree é churn de rebrand, fora do alvo.)

### Segurança (quality-specialist) — 7 vetores, **0 confirmado**

| Vetor | Estado | Sonda |
|---|---|---|
| RLS de verdade (role `movimento_app`, NOBYPASSRLS) | REFUTADO | GUC=clínica A lendo paciente de B → **0 linhas**; sem GUC → **0** (fail-closed); INSERT/UPDATE cross-tenant → `ERROR: new row violates row-level security policy`; UPDATE de linha alheia → `UPDATE 0` |
| Isolamento cross-tenant pela API | REFUTADO | ConnCase `GET /api/patients/:id` de outra clínica → 404; sem sessão → 401 |
| `clinic_id` do corpo ignorado | REFUTADO | dupla whitelist (`@campos` controller + `accept @campos` recurso); teste manda `clinic_id` no corpo e a resposta não o tem; foi para a clínica do escopo |
| RBAC por endpoint | REFUTADO | policies `read: :any` / `write: [:owner,:admin]` + guardas `with_member/admin_scope`; recepção/profissional → 403 |
| Escapada de path no BFF | REFUTADO | `encodeURIComponent`: `../../auth/sign-out` → `..%2F..%2Fauth%2Fsign-out` (um segmento); curl real → 401 na rota de patients, não sign-out |
| Fronteira de input | REFUTADO | `deactivate/reactivate` = `accept []`; update parcial não zera; `uf="ABC"`/`nome` 121ch/`cor_indice=100` → 422 |
| Vazamento em resposta/log | REFUTADO | `patient_json` sem `clinic_id`/timestamps; erro = `{"error":"unauthenticated"}`; `redact_sensitive_values_in_errors?: true` |

### Performance (data-engineer) — **0 bug**

| Achado | Estado | Sonda |
|---|---|---|
| Índice `clinic_id` | REFUTADO (existe) | `pg_indexes` → `patients_clinic_id_index btree (clinic_id)` |
| Plano da leitura por-tenant | CONFIRMADO saudável | `EXPLAIN`: `Index Scan using patients_clinic_id_index` (bench 10k = Bitmap+Sort, 21ms) |
| N+1 na listagem | REFUTADO | `grep load` no caminho do Patient = vazio; `patient_json` só escalares → 1 statement, não cresce com nº de linhas |
| FK/cascade + cobertura | CONFIRMADO correto | `\d patients`: FK `ON DELETE CASCADE` coberta pelo índice de `clinic_id` |

### Refatoração/DRY/rules (test-engineer)

| Achado | Estado | Ação |
|---|---|---|
| Paleta de avatar duplicada (`patientColor`/`profColor`) | CONFIRMADO (já drifou no estilo de parênteses) | **CONSERTADO** |
| `stripTitle` (Dr./Dra.) duplicado na fatia | CONFIRMADO | **CONSERTADO** |
| Comentário desatualizado `server/patients.ts` (path) | CONFIRMADO | **CONSERTADO** |
| Ladder de erro: PATCH inválido→422 não asseverado | CONFIRMADO (branch coberto via POST) | **CONSERTADO** (teste) |
| `in_clinic/2` triplicado (Records/Directory/Scheduling) | CONFIRMADO | **DECISÃO HUMANA** (código vizinho) |
| 3 listas de campos (`patient_json`/`@campos`×2) | REFUTADO como defeito | intencional (read≠write shape) |
| Dead code `applyActiveState`/exports sem uso | REFUTADO | remoção do `ativo` do BFF ficou limpa |
| Aderência às rules (ash.md/testes.md) | CONFIRMADO bom | sem Ash direto no web; code interface; sem validação redundante |

**Rodada 2 (adversarial) vs. rodada 1:** a caça por fluxo não abriu nenhum vetor que a
checklist não tivesse coberto — a RLS provada de baixo (role restrito) e a fronteira forçada
por ConnCase/curl fecharam os REFUTADO “fracos” da leitura em REFUTADO por sonda.

## 3. As causas-raiz

- **Token de design copiado à mão (risco de drift):** a paleta da agenda vivia duplicada em
  `patients.ts` e `professionals.ts` — e já havia divergido no estilo. Uma causa, dois sintomas.
- **Micro-repetição in-slice:** `stripTitle` em dois arquivos de pacientes.
- **Cross-cut de tenancy copiado a cada domínio novo:** `in_clinic/2` idêntico em três
  domínios — estrutural, o mesmo corte do `SetTenantGuc` (pendência já registrada).
- **Deferimentos de escala acoplados:** índice composto `(clinic_id, inserted_at)` + busca/
  paginação server-side (o load-all da lista e do aviso de duplicado).

## 4. O que foi corrigido (rodada 3) + re-sonda (rodada 5)

1. **Paleta extraída** para `web/src/lib/avatar.ts` (`AVATAR_PALETTE` + `avatarColor`);
   `patientColor`/`profColor` viraram re-export nomeado (call-sites intactos). Re-sonda:
   `npm run coverage` → **avatar.ts 100%, patients.ts/professionals.ts (lib) 100%**, 521/0.
2. **`stripTitle` extraído** para `patients.ts`, usado em `PatientForm.svelte` e na lista.
   Re-sonda: `svelte-check` 0/0.
3. **Comentário do `path/1`** corrigido (id vem de `event.params.id`, não de campo de form).
4. **Teste PATCH inválido→422** adicionado ao `patients_controller_test.exs`. Re-sonda:
   `mix test` → **17 testes, 0 falhas** (era 16).

**Gates finais (rodada 5):** backend `mix coveralls` **357 testes / 0, 89,1%, exit 0**; web
`npm run coverage` **521 / 0, 91,35%, exit 0**; `svelte-check` 0/0. O diff dos consertos não
abre superfície nova (extração pura + comentário + teste — sem endpoint/query/render/migration
novos), então a re-auditoria da rodada 5 não acende item novo.

## 5. O que ficou para você (decisão humana)

Nada de segurança nem de correção. Três itens estruturais/de escala, **não aplicados de
propósito**:

| Item | O que é | Sonda | Por que não corrigi | Correção sugerida |
|---|---|---|---|---|
| `in_clinic/2` ×3 | helper de tenancy (leitura) idêntico em Records/Directory/Scheduling | `grep "defp in_clinic"` → 3 arquivos | Escorrega para código vizinho (Directory/Scheduling, fora do diff); é o mesmo cross-cut do `SetTenantGuc` | `Api.Repo.with_clinic!/2` que desembrulha o `{:ok,_}`; os 3 domínios chamam. Fazer **junto** de mover `SetTenantGuc` para namespace neutro |
| ~~Índice composto `(clinic_id, inserted_at)`~~ | — | — | — | ✅ **FEITO** — ver §6 |
| ~~Busca/paginação server-side~~ | — | — | — | ✅ **FEITO** — ver §6 |

**Nota operacional (dev):** o subagente de segurança criou, para provar a RLS, as clínicas
`RLS Audit A`/`B` + 1 paciente cada em `movimento_dev` (INSERT/UPDATE cross-tenant foram todos
rollback/erro). É lixo de teste inofensivo; some com um `mix ash.reset` de dev quando quiser.

---

## 6. Follow-up entregue — paginação + busca server-side (mesma sessão)

Os dois deferimentos acoplados da §5 foram implementados logo depois da auditoria, juntos como
recomendado (o índice composto só paga com `LIMIT`).

### O que mudou

- **`read :list`** no `Patient`: argumentos `q` e `status`, `pagination offset?: true,
  countable: true, default_limit: 50, max_page_size: 200`.
- **`Api.Records.Preparations.FilterPatients`**: segmento (`ativos`/`inativos`/`resp`) e busca
  (nome por `ilike`; CPF/telefone comparando **dígitos contra dígitos**, porque a coluna guarda
  a máscara) — o que era `filterPatients`/`searchPatients` no cliente.
- **Ordem total**: o sort virou `[inserted_at: :asc, id: :asc]`. Sem o desempate, duas linhas
  com o mesmo `inserted_at` podem repetir ou sumir entre páginas.
- **Índice**: `[:clinic_id]` **substituído** por `[:clinic_id, :inserted_at]` (migration
  `add_patients_pagination_index`) — o composto cobre tenant, FK e ordenação, então o simples
  virava redundante.
- **Contagens da sidebar** (`clinic_patient_counts/1`) passaram para o servidor: com a lista
  paginada, contar o que chegou contaria só a página. Independem da busca (como o `sbPacientes`
  do protótipo). `inativos` é derivado (total − ativos).
- **Web**: `?q=`/`?filter=`/`?page=` na URL; busca com debounce de 300ms que navega; controles
  Anterior/Próxima com "X–Y de Z"; sidebar consumindo `counts`.
- **Fim do último carrega-tudo**: o aviso de duplicado não baixa mais o cadastro inteiro em
  `/novo` e `/editar` — virou `GET /api/patients/lookup`, disparado só quando o CPF (11 díg.)
  ou o telefone (10+) ficam completos, devolvendo apenas `{id, nome, cpf, tel}`.

### Sonda do plano (o que motivou tudo)

Bench em tabela **TEMP** sintética (200k linhas / 20 clínicas ⇒ 10k por clínica), forma exata da
query enviada (`WHERE clinic_id = … ORDER BY inserted_at, id LIMIT 50`):

```
B) COM o composto (clinic_id, inserted_at) — primeira página
 Limit (actual time=0.040..0.064 rows=50)  Buffers: local hit=17 read=4
   -> Incremental Sort  Sort Key: inserted_at, id   Presorted Key: inserted_at
        -> Index Scan using pbench_clinic_inserted  Index Cond: (clinic_id = …)
 Execution Time: 0.079 ms

C) COM o composto, página profunda (OFFSET 5000)
 Limit (actual time=11.099..11.106 rows=50)  Buffers: local hit=4 read=3227
   -> Sort  Sort Key: inserted_at, id   Sort Method: quicksort  Memory: 1713kB
        -> Bitmap Heap Scan  Heap Blocks: exact=3178
 Execution Time: 11.129 ms
```

Duas conclusões medidas:

1. O índice **é usado** na página inicial (o caso comum) e o desempate por `id` **não** custa um
   sort completo — vira *Incremental Sort* sobre a chave já pré-ordenada pelo índice.
2. **Offset profundo degrada** (0,079ms → 11ms no offset 5000). É o limite conhecido da
   paginação por offset; a saída natural do usuário é buscar (que estreita o conjunto), não
   paginar até a página 101. Se um dia isso incomodar, o conserto é **keyset** — que o eixo
   prev/próxima da tela já comporta, mas que impede "pular para a página N".

### Gates depois do follow-up

Backend **380 testes / 0 · 89,5%** (17 novos em `patient_list_test.exs` + 6 no controller);
web **530 testes / 0 · 91,37%**; `svelte-check` 0/0; `npm run build` ✓. Todos exit 0.

---

## 7. Segunda auditoria — a superfície de paginação/busca/lookup

Rodada depois dos commits `5d2a0f7`/`3a02e15`, com alvo **só no que a §6 acrescentou** (repassar
código já auditado não acha nada). Três eixos em paralelo, cada achado provado por sonda.

### O que veio de cada eixo

| Eixo | Resultado |
|---|---|
| Segurança | **2 CONFIRMADOS** (ambos de *disponibilidade*, nenhum de dado), 5 REFUTADOS |
| Performance | **0 bug** — página sem busca em 0,09ms, scan da busca contido ao tenant |
| Refatoração | **2 bugs reais** de ciclo de vida no web + 1 DRY + 3 lacunas de teste |

**REFUTADOS com prova** (não repetir a suspeita): injeção SQL no `fragment` (é bind param — o
payload `1'; SELECT 1--` chegou como valor em `$1`, e o parâmetro dos `regexp_replace` já vem
reduzido a dígitos); OFFSET gigante como DoS (13,8ms no absurdo vs 11,3ms na última página real
— o Postgres para no fim dos dados); auth/cross-tenant/vazamento no `/api/patients/lookup` (sem
cookie → `{"matches":[]}` porque a API nega 401; projeção mínima; sem CORS); enumeração de CPF
(superfície estritamente menor que o `GET /api/patients` que o papel já tem); `to_existing_atom`
(guard de whitelist antes da conversão); tenant sob paginação/contagem (RLS cortou a sonda sem GUC).

### Causa-raiz 1 — o input chega ao Postgres com o tipo normalizado, mas não a **forma**

- **`%`/`_` digitados viravam curinga.** `"%#{term}%"` interpolava metacaractere direto no
  padrão. Não é injeção (o valor é parâmetro), mas é amplificação de custo: 8000 chars de `a%`
  = **6,7s por query**, e cada `GET` roda o padrão **duas vezes** (página + count) — ~850ms de
  CPU de banco por request a 10k pacientes, ~68× a busca normal. Qualquer membro ativo dispara.
- **`offset` sem teto** estourava o int64: `?page=` gigante → `DBConnection.EncodeError` → **500**
  (não há `action_fallback` no controller).

**Consertado:** escape de `%`/`_`/`\` (`escape_like/1`) + teto de 100 chars no termo; `@max_offset
100_000` no clamp. Re-sonda (o mesmo `inspect` do filtro que achou o bug):

```
antes:  termo="%"  ->  ilike(nome, "%%%")        (casava a clínica inteira)
depois: termo="%"  ->  ilike(nome, "%\%%")       (literal)
        termo="mari" -> ilike(nome, "%mari%")    (busca normal intacta)
```

### Causa-raiz 2 — timers sem cleanup no web

- **O debounce da busca sequestrava a navegação** (médio): digitar e clicar numa linha em menos
  de 300ms deixava um timer órfão que chamava `goto` e **arrastava a pessoa de volta** para a
  lista — remontando a querystring a partir da URL da ficha, que já era outra.
- `dupTimer` do formulário: mesma classe, só desperdiça uma consulta (baixo).

**Consertado:** `onDestroy` limpando os dois.

### Causa-raiz 3 — o `$effect` de sinc comia caractere

Com um load em voo, a resposta do termo *antigo* chegava depois da tecla nova e devolvia o input
ao valor velho: a tecla seguinte produzia `mai` em vez de `mari`. **Consertado** com uma guarda
`digitando` (propositalmente não-reativa: se fosse `$state`, o próprio efeito voltaria a rodar
quando ela mudasse, que é o oposto do que se quer).

### Lacunas de teste fechadas

O eixo de refatoração observou que **os dois bugs médios viviam no único arquivo da fatia sem
teste de componente** — não era coincidência. Foram criados: `page.svelte.test.ts` (6 testes,
incluindo regressão do timer órfão e do clobber de digitação), o teste de que **as contagens
ignoram a busca** (decisão de produto que não tinha backstop) e o de **busca combinada com
página >1** via HTTP.

### Gates

Backend **387 testes / 0 · 89,5%**; web **536 testes / 0 · 91,38%**; `svelte-check` 0/0. Exit 0
nos dois.

### O que ficou para você (com número)

| Item | Número medido | Recomendação |
|---|---|---|
| 3 counts da sidebar → 1 com `COUNT(*) FILTER` | 29,1ms → 10,4ms (**−64%**), 5 → 3 scans por carga | Ganho barato, mas custa o reuso da ação `:list` (hoje contador e lista não podem divergir). Trade-off consciente |
| `countable: true` paga 2× o scan da busca | +47,1ms no pior caso (termo sem match) | Aceitar — o "de Z" da tela exige total exato |
| `regexp_replace` em CPF/tel | 35,5ms dos 48,9ms do pior caso | Manter. Reabrir com índice de expressão/`pg_trgm` se algum tenant passar de ~50k pacientes (≈250ms) |
| `replaceState: true` no `goPage` | — | Voltar a partir de `?page=3` sai da lista inteira em vez de ir para a página 2. Escolha de produto |
