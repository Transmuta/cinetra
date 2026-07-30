# Auditoria bate-volta — Fatia "Gestão da clínica / Membros"

Data: 2026-07-13. Método: skill `bate-volta` (caça em rodadas contra a **stack rodando**,
`docker compose`). Três frentes em paralelo (segurança → `quality-specialist`, performance →
`data-engineer`, refatoração/DRY/rules → `test-engineer`), cada achado provado por sonda.
Alvo: só o diff da fatia (shell admin + Equipe & acessos + backend de convite/membros).

## 1. Onde parou, e por quê

Parou na rodada 5 (verificação). A rodada 1 (checklist) achou dívidas de DRY/rules; a rodada 2
(adversarial, seguindo os fluxos reais) achou **todos os quatro CONFIRMADOs de segurança** e o
`svelte-check` quebrado — os itens que a checklist não pega. Consolidado por causa-raiz,
consertada a fila local em TDD, e re-sondado cada conserto na app viva.

**Resultado: 5 defeitos locais corrigidos (4 de segurança + 1 de infra) + 1 bloqueio de CI + 3
menores. 4 itens estruturais ficaram para decisão humana. Performance: zero defeitos.**

## 2. A varredura (resumo)

| Eixo | Itens checados | REFUTADO / N.A. | CONFIRMADO |
|---|---|---|---|
| Segurança | 15 classes de ataque | 12 refutados, 3 N.A. | **A, B, C, D** (4) |
| Performance | 7 frentes (EXPLAIN/contagem) | 7 refutados | 0 (2 notas estruturais) |
| Refatoração | DRY + ash.md + elixir + svelte + cobertura | maioria OK | phantom, infra, CI, +menores |

O que a rodada 2 pagou: os quatro CONFIRMADOs de segurança e o phantom user saíram **só** da
caça adversarial (seguir convite → sign-in → ativação; e a policy de `update` de papel).

## 3. Causas-raiz e o que foi corrigido (fila local)

Ordem: segurança → infra → CI → DRY. Cada um: sonda que achou · teste vermelho · re-sonda.

### A — Takeover: admin se autopromovia a owner (ALTA) ✅ corrigido
- **Sonda:** `mix run` — "ADMIN SELF-PROMOTION TO OWNER: SUCCEEDED" + rebaixou o owner original.
  A policy de `update`/`revoke` autorizava qualquer owner/admin, e `update` aceita `papel`;
  `NotLastOwner` não protege (o admin vira owner *antes*).
- **Causa-raiz:** faltava a regra **D23** ("só owner gerencia owners").
- **Correção:** validação `RestrictOwnerRole` nas ações `:update` e `:revoke_access` — operação
  que envolve owner (promover a owner, ou alterar/revogar um owner) exige actor owner ativo.
  Escopada por ação (não `on: [:update,:destroy]`), senão barraria o `accept_invite` de um
  convite de owner (o onboard).
- **Teste:** 6 casos (admin não promove/autopromove/rebaixa/revoga owner; owner promove; admin
  ainda gere não-owner). **Re-sonda:** `mix run` → `A_admin_autopromocao_BLOQUEADA: true`.

### Phantom user: convite negado criava User no banco (ALTA) ✅ corrigido
- **Sonda:** um convite `Forbidden` (recepção) deixava "PHANTOM USER CRIADO" — o `register_user!`
  rodava no corpo do `change/3`, que executa na montagem do changeset, **antes da policy**.
- **Correção:** mover a resolução do user para `Ash.Changeset.before_action/2` (roda pós-
  autorização e dentro da transação) em `ResolveInvitedUser`.
- **Teste:** convite negado não cria o User (`Ash.Query` confirma lista vazia). **Re-sonda:**
  `phantom_convite_FORBIDDEN: true` + `phantom_SEM_user_criado: true`.

### D — `professional_id` cross-tenant sem validação (BAIXA-MÉD) ✅ corrigido
- **Sonda:** `curl` PATCH apontou um vínculo de Clínica Verify para um `Professional` de Centro
  → HTTP 200 (ponteiro cross-tenant no `Membership` global).
- **Correção:** validação `ProfessionalInClinic` em `:invite_by_email` e `:update` — quando
  `professional_id` está presente, precisa ser um `Professional` da clínica da ação. A leitura
  usa `Api.Directory.professional_in_clinic?/2`, que roda sob o GUC de tenant (RLS).
- **Teste:** vincula da própria clínica (ok) / de outra (Invalid). **Re-sonda (RLS, stack viva):**
  `curl` com professional válido → **201**; cross-tenant → **422** "profissional não pertence a
  esta clínica".

### Infra — `Api.Repo.with_clinic`/`Ash.load!` vazaram para o controller (MÉD) ✅ corrigido
- **Sonda:** leitura de `members_controller.ex` (Repo/data-layer num web module, contra ash.md).
  Raiz: a leitura por-tenant de `Professional` sob RLS precisa de transação p/ setar o GUC.
- **Correção:** `Api.Directory.list_clinic_professionals/1` (centraliza o `with_clinic` na camada
  de domínio) + `load: [:user]` via code interface (no lugar do `Ash.load!`).
- **Re-sonda:** `GET /api/members` sob `cinetra_app` → `professionals: ['Dra. Ana Livre']`
  (a isolação e o retorno seguem corretos).

### CI — `svelte-check` quebrado (bloqueava o job web) ✅ corrigido
- **Sonda:** `npm run check` → 2 erros em `equipe/page.server.test.ts` (acesso a `r.members` sem
  o cast que o retorno `void` de `PageServerLoad` exige).
- **Correção:** helper `runLoad` com cast (espelha `routes/page.server.test.ts`). **Re-sonda:**
  `svelte-check found 0 errors and 0 warnings`.

### Menores ✅
- `initials()` duplicado (Topbar + página) → `$lib/format.ts` (+ teste).
- `on:keydown` legacy → `onkeydown` (runes) no modal.
- Sombra teal crua no Rail → token `--mv-shadow-teal` / `shadow-teal`.

## 4. Verificação final (rodada 5)
- Backend: **83 testes, 0 falhas** (+9 da auditoria). Cobertura **79,4%** (era 72,1% no
  baseline do `develop`; a fatia+fixes subiram +7,3pp — o gate segue na dívida pré-existente do
  `release.ex`, fora do escopo, ver §5).
- Web: **122 Vitest, 0 falhas**; `svelte-check` limpo; gate de cobertura **95,7%** (verde).
- Todos os fixes RLS-sensíveis re-provados contra `cinetra_app` + o phx.server.
- Diff dos consertos auditado: sem achado novo. Resíduo benigno anotado — re-convite duplicado
  pode deixar um `User` órfão (sem membership); inofensivo.
- Artefatos de sonda no DB de dev (writes das auditorias) removidos.

## 5. Para decisão humana (estrutural — não corrigido no impulso)

1. **B — Ativação de convite em massa / sem consentimento (segurança, MÉD).** `activate_pending`
   ativa **todos** os `Membership` pendentes do usuário em **qualquer** sign-in. Vetor: um
   atacante convida `victim@x` para a clínica dele; a vítima loga por conta própria e entra na
   clínica do atacante sem consentir (e, como `invite_by_email` acha-ou-cria o User, dá para
   pré-criar conta+vínculo; o `default_membership` por `inserted_at` pode virar o tenant default
   da vítima). **Sonda:** `mix run` mostrou o pendente virar ativo após o sign-in da vítima.
   **Correção candidata:** aceite **por convite** — o magic link do convite carregar o
   `membership_id`/`clinic_id` e ativar só aquele vínculo, ou uma tela de aceite. Muda o modelo
   de token (estrutural). Alinha com D24.

2. **C — Convite fora do rate-limit (segurança/cobertura, MÉD).** `POST /api/members` está em
   `[:api, :authenticated]`, sem `:rate_limited`, mas dispara `request_magic_link` → relay de
   spam / criação ilimitada de User+membership. **Correção candidata:** cobrir a rota no
   `:rate_limited` com chave por **actor + e-mail-alvo** (o limiter atual é por IP e no-op fora
   de produção). Requer estender o `RateLimitAuth`.

3. **RLS dá falsa confiança nos testes (infra de teste).** `mix test`/`mix run` conectam como
   `postgres` (superuser, **bypassa RLS**), então a asserção de `professionals` no controller
   passaria **mesmo sem** o `with_clinic`. **Sonda:** `professionals count` = 7 (postgres) vs 0
   (`cinetra_app` sem GUC). O bug de RLS desta fatia só foi pego por verificação no
   browser/`curl`. **Correção candidata:** um teste que conecte como `cinetra_app`
   (NOBYPASSRLS) provando que sem GUC a leitura zera e com GUC filtra — decisão de infra de
   testes (o Ecto Sandbox complica trocar de role).

4. **Tela `equipe/+page.svelte` sem teste automatizado.** Fora do `include` de cobertura
   (`src/routes/**/*.svelte`) e sem e2e; a lógica de render (flash, `semAcesso`, modal,
   `confirmRevoke`, reenviar) não é exercida por unit — só pela verificação manual no Playwright
   desta sessão. **Correção candidata:** um `.svelte.test.ts` da página ou um e2e do fluxo
   convidar→listar→editar→revogar (mesma escolha "página por e2e" que o projeto já adota).

### Notas de performance (informativas, sem defeito)
- `activate_pending` é O(N) não-batelado no sign-in — irrelevante no volume esperado (1–3
  convites/pessoa); se o fan-out crescer, trocar por `Ash.bulk_update`.
- O índice de `clinic_id` em `memberships` é incidental (herdado da identity composta
  `unique_professional_link`); se essa identity mudar, criar `CREATE INDEX ON memberships
  (clinic_id, inserted_at)`.
