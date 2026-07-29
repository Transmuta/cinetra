# 21 — Auditoria bate-volta: Tipos de atendimento

Auditoria em rodadas da fatia "Tipos de atendimento" (diff não-commitado), provando cada achado
contra a **stack rodando** (psql como `cinetra_app`, `mix test`, `curl` na API, logs, corrida
HTTP real). Método: caça (rodadas 1–2) → consolidação → conserto (3) → verificação (5).

Regra do método: **sem output de sonda, o achado não existe.** Alvo: `git diff HEAD` + arquivos
novos da fatia (~3.200 linhas), backend `api/` + frontend `web/` + `docs/20`.

## Onde parou

Fechou na rodada 5. As três caças rodaram (segurança rodada por mim após o subagente ser
interrompido no meio; ele havia sinalizado dúvida no próprio achado). Consertados **B**, **C** e a
higiene barata; **A** e **D** viram handoff por serem estruturais/desproporcionais.

## A varredura

| Eixo | Item | Estado | Sonda |
|---|---|---|---|
| **Seg** | RLS leitura cross-tenant | REFUTADO | `cinetra_app`, GUC=A → vê 6 de A, **0** de B |
| **Seg** | RLS escrita cross-tenant (INSERT/UPDATE) | REFUTADO | INSERT clinic_id=B → `violates row-level security policy`; UPDATE de B → `UPDATE 0` |
| **Seg** | Fail-closed (sem GUC / GUC-lixo) | REFUTADO | `cinetra_app` sem GUC → **0**; GUC-lixo → **0**. (O "14 linhas" do subagente era `postgres`/BYPASSRLS) |
| **Seg** | `pre_check?` vaza existência cross-tenant | REFUTADO | 3 linhas "Sessão" em 3 clínicas distintas (seria 1 se fosse global) |
| **Seg** | RBAC recepção escreve | REFUTADO | controller **e** policy: `recepção não cria/atualiza/arquiva/restaura` (403), testes verdes |
| **Seg** | 2ª porta via AshJsonApi | REFUTADO | `AshJsonApiRouter` só expõe `Api.Meta`; `GET /api/json/appointment*` → 404 |
| **Seg** | `clinic_id` do corpo aceito | REFUTADO | teste "IGNORA clinic_id do corpo" verde |
| **Seg** | `set_clinic_guc/1` público explorável | REFUTADO | 2 chamadores, tenant sempre de `changeset.tenant`/`tenant_from_reason`; sem caminho de input |
| **Seg** | Breadcrumb no 422 | CONFIRMADO (baixo, pré-existente) | vaza nome de módulo/ação na resposta crua; **o BFF descarta** (`errorMessage` só lê `error==='invalid'`) — não chega ao browser |
| **Perf** | N+1 na `calculate :sigla` | REFUTADO | log: **1** SELECT para 7 linhas; `load/3 → [:nome]` |
| **Perf** | RLS bloqueia index scan | REFUTADO | plano vira `One-Time Filter`, avaliado 1×; a 120k linhas `Bitmap Index Scan` |
| **Perf** | `pre_check?` caro | REFUTADO | 1 SELECT, `Index Scan using ...unique_nome_index`, 0.05ms |
| **Perf** | Índice `[:clinic_id]` redundante | **CONFIRMADO (D)** | `idx_scan=0`; prefixo estrito de `(clinic_id,nome)` |
| **Ref** | Comentário `cap_turma_padrao` falso | **CONFIRMADO (B)** | diz "NENHUM endpoint expõe"; `curl` → `cap_turma_padrao: 4` |
| **Ref** | `fetchMembers` sem try/catch | **CONFIRMADO (C)** | load da equipe tem `\|\| 502` que exige status 0 que `fetchMembers` nunca produz |
| **Ref** | `encodeURIComponent` assimétrico | **CONFIRMADO (C)** | tipos escapa o id, members não |
| **Ref** | 48 linhas duplicadas nos 2 controllers | CONFIRMADO (handoff) | `diff` dos blocos: 47 byte-idênticas |
| **Ref** | `error_field` fallback = bug latente no Members? | REFUTADO | `InvalidChanges` (com `fields:`) só nasce do `pre_check?`, que só este recurso tem |
| **Ref** | Cobertura de fachada (modal/Arquivados) | REFUTADO | `TypeModal` 94%/14 testes; só o render do `.svelte` fora (doc 16 sanciona) |

### O que a rodada 2 (adversarial) achou que a 1 não tinha

**A corrida do `pre_check?` (achado A)** — a rodada 1 tratou o `pre_check?` como cura do 500 de
nome duplicado. A rodada 2 perguntou "e sob concorrência?" e provou que **não é**.

## As causas-raiz

- **A — a corrida do `pre_check?` reabre o 500.** O pre-check não segura lock; dois POSTs
  concorrentes de nome idêntico passam ambos, um bate no índice único, e sob RLS o Postgres
  **omite o `DETAIL`**, que o AshPostgres lê sem proteção → *raise* → HTTP 500. É a mesma
  causa que o `pre_check?` tentou matar, só estreitada para a janela da corrida.
- **B — deriva factual (introduzida ao adicionar `cap_turma_padrao` tarde).** Comentário e teste
  no front descreviam um mundo onde o endpoint não expõe o campo; ele passou a expor.
- **C — extração pela metade.** `mutate.ts` levou a mutação, deixou a leitura duplicada, e foi lá
  que os contratos divergiram (`try/catch`, escape de id).
- **D — índice redundante** copiado do `Professional`, onde é necessário.

## O que foi corrigido (rodada 3, TDD)

### B — `cap_turma_padrao`: comentário + tipo obrigatório + teste honesto
- **Sonda que achou:** subagente de refatoração leu o comentário; `curl` provou o campo existe.
- **Conserto:** `web/src/lib/appointment-types.ts` — `cap_turma_padrao?` → obrigatório, comentário
  reescrito. `page.server.test.ts` — o teste que mockava a forma inexistente virou "resposta
  malformada → default defensivo" (com cast explícito), e os mocks válidos ganharam o campo real.
- **Re-sonda (rodada 5):** `curl GET /api/appointment-types` → `{"cap_turma_padrao": 4, ...}`;
  `svelte-check` 0 erros; suíte verde.

### C — `fetchMembers` try/catch + escape de id
- **Sonda que achou:** o load da equipe faz `error(result.status || 502)`, que só funciona com
  status 0 — e `fetchMembers` (sem try/catch) **lança** em vez de devolver 0 → 500, não 502.
- **Teste vermelho:** `members.test.ts` — "exceção de rede → status 0, data null (não propaga)" e
  "escapa o id na URL". Ambos falharam pelo motivo certo antes do conserto.
- **Conserto:** `members.ts` — `try/catch` no `fetchMembers` (mesmo contrato do BFF de tipos);
  `memberPath/1` com `encodeURIComponent`.
- **Re-sonda:** os 2 testes verdes; suíte members 11/11.

**Verificação global:** web **240** testes / 0 falhas / 96,63% stmts; backend **183** / 0 falhas /
84,1%; `svelte-check` 0; `mix format --check-formatted` OK.

## O que ficou para você

### A — corrida do `pre_check?` → HTTP 500 (não corrigido: estrutural)
- **O que é:** duplo-clique / dois admins criando um tipo de mesmo nome na mesma clínica ao mesmo
  tempo → um dos requests devolve **500 (página HTML do Phoenix)** em vez de 422. O dado **não**
  corrompe (o índice único segura — 1 linha persiste).
- **Sonda:** 20 rodadas × 8 POSTs concorrentes → **15 respostas 500**. Stack trace:
  `ash_postgres 2.10.0 lib/data_layer.ex:3353` (`detail: error.postgres.detail`). No psql,
  `cinetra_app` recebe o `unique_violation` **sem `DETAIL`**; `postgres` recebe com.
- **Por que não corrigi:** a raiz é o AshPostgres lendo `error.postgres.detail` sem proteção
  quando o Postgres omite o DETAIL sob RLS. As correções são decisão de arquitetura — (a) bump do
  `ash_postgres` para versão que faça acesso seguro à chave; (b) advisory lock por
  `(clinic_id, nome)` antes do INSERT, eliminando a corrida; (c) `try/rescue` no domínio mapeando
  o `unique_violation` para 422. Nenhuma é um patch de rodada 3 de baixo risco.
- **Nota:** o comentário da identity em `appointment_type.ex` chama o índice de "rede de
  segurança" para a corrida — mas sob RLS ele produz 500, não um 422 limpo. Corrigir junto.

### D — índice `custom_indexes index [:clinic_id]` redundante (não corrigido: desproporcional)
- **O que é:** prefixo estrito da identity `(clinic_id, nome)`; `idx_scan = 0`, ~12 B/linha de peso
  morto numa tabela quase nunca escrita.
- **Por que não corrigi:** remover exige cirurgia de migration (regenerar a `add` limpa força
  renomear a RLS escrita à mão para depois dela; a alternativa deixa um add-depois-drop na fatia).
  Risco de errar migration > ganho de 12 B/linha. A árvore ficou consistente (índice presente em
  recurso + migration + snapshot; `mix ash.codegen --check` sem drift).
- **Correção:** ao finalizar/squashar as migrations da fatia, tirar o bloco `custom_indexes` do
  recurso e regenerar — deixando a `add` sem o índice e a RLS depois dela.

### Refatoração adiada (handoff — mexe na fatia de Membros já commitada, ou é higiene)
- **Extrair `ApiWeb.ScopeGuards`** (48 linhas idênticas nos 2 controllers, via `use ApiWeb`):
  levar a versão com `error_field/1` (fallback de `:fields`), que é estritamente mais geral. O
  usuário pediu para *copiar* o shape nesta fatia — a extração é a próxima decisão consciente.
- **`sign_in/1`/`authed/2` → `ConnCase`** (3 cópias byte-idênticas; o regex do magic link já
  mudou uma vez em `8d910af`).
- **`in_clinic/2` para `list_clinic_professionals`** (6 linhas viram 1, mesmo módulo).
- **`Field.svelte`**: `name` virou opcional além do necessário — `<Field label>` sem `name` nem
  `children` renderiza input anônimo que não submete. Union discriminada devolve a garantia.
- **`errorMessage`/`MutationResult` re-exportados sem chamador** em `mutate.ts`/`members.ts`
  (deleção); `doctest` da `Sigla` (o projeto não roda os exemplos do `@doc`).
- **Contrato da paleta**: `@cores`/`@icones` (Elixir) e `TYPE_COLORS`/`TYPE_ICONS` (TS) batem hoje,
  nada amarra. Uma 9ª cor só no front vira swatch que 422a. Teste de contrato ou endpoint de meta.
