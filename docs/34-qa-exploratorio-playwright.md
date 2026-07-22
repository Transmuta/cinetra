# 34 — QA exploratório (Playwright) — varredura ponta-a-ponta

Sessão de teste exploratório dirigida por navegador (Playwright) + sondas de API/BFF
autenticadas + verificação no banco, cobrindo os fluxos entregues até aqui (agenda,
pacientes, profissionais, equipe, configurações, fila, notificações, auth).

- **Ambiente:** app rodando em container (`web` :5173, `api` :4010, `db` :5434), branch `develop`.
- **Ator:** `agenda.demo@example.com` (owner de *Clínica Agenda Demo* — o tenant com mais dados:
  6 profissionais, 10 pacientes, 10 agendamentos, 5 tipos).
- **Login:** magic link real, gerado via `request_token_for` + `MagicLinkToken.seal/1` e trocado
  no `/auth/callback` (o token cru NÃO autentica — o `UnsealMagicLinkToken` exige o selo, o que
  é o comportamento correto e foi confirmado).

## Ressalvas de método (afetam a confiança de alguns pontos)

1. **Ferramentas do MCP Playwright degradadas:** `browser_snapshot` e `browser_evaluate`
   retornaram erro em toda chamada; `browser_type` não dispara o evento `input` que o
   `bind:value` do Svelte precisa (botões com `disabled={!canSave}` ficam travados). Por isso a
   verificação de *submits* interativos foi feita reproduzindo a *form action* via `curl`
   autenticado — não pela UI. Renderização foi verificada por screenshot.
2. **Edição em paralelo durante o teste:** o working tree tinha WIP não commitado
   (*Relatórios/Fatia 9* — `scheduling.ex`, `reports_controller.ex`, `docs/33`) que **não
   compilava** (`imported Kernel.min/2 conflicts with local function`); foi corrigido ao vivo
   durante a sessão (`Kernel.min` qualificado). Enquanto o `api` recompila, **todas as páginas
   piscam para 500** (sem degradação graciosa — some a contagem da sidebar, aparece "500").
   Todo 500 foi re-testado antes de virar achado; os transientes NÃO estão na lista abaixo.

---

## Achados

### F1 — `/auth/callback` engole falha de autenticação e manda para `/` (deveria mostrar erro) · **médio**

Um magic link inválido/expirado/adulterado cai em `/` (a landing pública), **sem nenhuma
mensagem**, deixando o usuário deslogado achando que "algo aconteceu".

| Entrada no `/auth/callback` | Resultado observado | Esperado |
|---|---|---|
| token lixo/expirado | `303 → /` | `303 → /entrar?erro=…` |
| sem token | `303 → /entrar?erro=link` ✔ | ok |
| (contraste) API direto `/api/auth/magic-link/callback` com token ruim | `401 → /entrar?erro=magic_link` ✔ | ok |

**Causa:** `reemitSession()` ([web/src/lib/server/api.ts](../web/src/lib/server/api.ts)) considera
sucesso a mera **presença de `Set-Cookie`** — mas a API emite o cookie `_api_key` (sessão vazia)
**mesmo no 401**. O callback então segue para `/`, perdendo o `erro=magic_link` que a própria API
sinalizou.
**Não é bypass de sessão** (o cookie reemitido é uma sessão vazia — `/api/auth/me` segue 401).
É correção/UX/confiança.
**Sugestão:** decidir sucesso pelo `res.status`/`Location` da API (2xx / redirect para raiz),
não pela existência de cookie.
**Repro:** `curl -s -o /dev/null -w "%{http_code} %{redirect_url}" "http://localhost:5173/auth/callback?token=XCP.lixo"`

### F2 — UUID malformado nas rotas de detalhe → 500 (`CaseClauseError`) · **baixo**

`GET /api/patients/:id` e `GET /api/professionals/:id` (e, por tabela, as páginas do BFF
`/pacientes/<x>` e `/profissionais/<x>`) estouram **500** quando o `id` não é um UUID.

```
GET /api/patients/not-a-uuid      -> 500
GET /api/patients/123             -> 500
GET /api/professionals/not-a-uuid -> 500
/pacientes/not-a-uuid  (BFF)      -> 500
/profissionais/not-a-uuid (BFF)   -> 500
```

**Log:** `** (CaseClauseError) no case clause matching: {:error, %Ash.Error.Invalid{errors:
[%Ash.Error.Query.InvalidArgument{field: :id, message: "is invalid", value: "not-a-uuid"}]}}` — o
`case` do `show` só trata `{:ok, _}` e `NotFound`, não o `InvalidArgument`.
**Inconsistente com os vizinhos**, que já tratam: `…/appointments/xyz/cancel → 404`,
`…/professionals/xyz/deactivate → 422`.
**Sem vazamento** (exige auth, não revela dado), mas é crash não tratado — deveria ser 404.
**Afeta:** `PatientsController.show`, `ProfessionalsController.show`.

### F3 — Contagens da sidebar mostram "0" nas telas de detalhe/novo · **baixo (cosmético)**

Na lista `/pacientes` os segmentos mostram `10 / 4 / 6` corretamente; em `/pacientes/[id]`,
`/profissionais/novo` etc. a mesma sidebar mostra **`0 / 0 / 0`**. Determinístico (a ficha carrega
normalmente — só as contagens vêm zeradas). As contagens vêm do `+page.server.ts` da **lista**
(`pat.data.counts`); telas de detalhe/novo não as fornecem → o `Sidebar` cai no default `0`.
Mostrar "0" (havendo 10) engana. **Sugestão:** ocultar a contagem quando ausente, ou carregá-la
no layout.

### F4 — Máquina de estados do agendamento sem *guard* de status de origem (servidor aceita qualquer transição) · **médio**

As ações de ciclo de vida do agendamento (`reopen`, `cancel`, `mark_completed`, `mark_missed`,
`set_falta_justificada` em [appointment.ex](../api/lib/api/scheduling/appointment.ex)) **setam o
status de destino sem validar o status atual**. O único guard é `SessionStarted`
(concluir/faltar). Provado por chamada direta à API (owner autenticado, clínica própria):

| Transição disparada | Origem→Destino | HTTP | Efeito real |
|---|---|---|---|
| `reopen` em já-agendado | agendado→agendado | 200 | sem mudança de status, mas **bump de `version` + entrada de trilha "reopen"** (auditoria fantasma) |
| `justify-absence` em agendado | (nunca faltou) | 200 | grava trilha "set_falta_justificada" e cascateia "justificada" para presenças que nunca foram falta |
| `cancel` após `complete` | concluido→cancelado | 200 | **mudança de dado real** — transição inválida aceita |

A UI esconde os botões inválidos por status, então só é alcançável por **chamada direta à API,
UI velha ou corrida**. **Não é cross-tenant** (agendamento de outra clínica → 404). Impacto:
integridade de **dado e de trilha de auditoria** (a auditoria é superfície de compliance no
doc 25); entradas fantasma/ inválidas e "falta justificada" sobre algo que não faltou distorcem o
agregado de faltas.
**Sugestão:** validar o status de origem em cada ação (ex.: `validate attribute_in(:status,
[origens_permitidas])`).
**Divulgação de teste:** no agendamento `019f7c64-0836-77a7-a641-81a89b2d942e` ficaram **5 versões
extras** de trilha (append-only; o status foi **restaurado para `agendado`**) e 1 notificação foi
gerada pelas transições.

### Nits menores

- 404 "Em construção" oferece como retorno **"Ir para Equipe & acessos"** — arbitrário; "agenda"/home
  seria mais natural.
- Sem degradação graciosa quando a API dá 500 no meio de um recompile (página inteira → 500 /
  contagens zeradas). Sintoma só de dev.

---

## O que foi exercitado e passou (sem defeito)

- **Renderização OK** (screenshot): `/entrar`; agenda **Dia / Semana / Mês / Lista** (com dados no
  dia 20/07 — 9 agendados + 1 cancelado, ocupação, "Sem expediente", cancelado riscado, badges
  ENCAIXE/AÇÃO); `/pacientes` (lista + ficha, com Pacotes/Histórico/Anexos ocultos como esperado);
  `/profissionais` (lista, filtros Todos/Ativos/Inativos = 6/2/4); `/configuracoes/equipe`,
  `/clinica`, `/tipos`, `/horario`, `/excecoes`, `/auditoria`; `/fila` e `/notificacoes` (estados
  vazios); 404.
- **Isolamento por tenant (RLS) — sólido.** Como owner da *Agenda Demo*, tentativas contra outra
  clínica:
  - Leitura: `/pacientes/<outra>` e `/profissionais/<outra>` → **404**; próprios → 200;
    `/api/patients` escopado (total = 10 da própria clínica).
  - Escrita: `PATCH`/`deactivate` de paciente alheio, `cancel`/`complete` de agendamento alheio,
    `deactivate` de profissional alheio → **todos 404**, dado inalterado.
- **Validação de entrada** (majoritariamente 4xx, exceto F2): JSON quebrado → 400; criar paciente
  sem nome / criar agendamento sem campos → 422; UUID válido inexistente → 404.
- **CNPJ (alfanumérico, regra Serpro):** `"123"`/zeros/`"ZZ…"` → 422; `"12.ABC.345/01DE-35"` (válido)
  → 200; nome vazio → 422. *(o CNPJ da clínica foi alterado no teste e revertido para `null`.)*
- **Criar profissional** (happy-path via BFF `?/save`, só nome): 200, persistido — e o registro de
  teste foi **removido** depois.

## Cobertura não concluída / sugestões de follow-up

- Submits interativos pela UI (drawer de agendamento, criar/editar paciente e profissional pelos
  formulários, modais de fila) — bloqueados pelas ferramentas do MCP (ver ressalva 1); recomendo
  cobrir por Playwright e2e "de verdade" no `web/`.
- `switch-clinic` não exercitado (o owner de teste só tem uma clínica).
- Fila/vagas e o tempo real (WebSocket) só validados na renderização vazia — faltou o caminho com
  fila populada.

---

## Resolução (2026-07-21)

Todos os quatro achados foram corrigidos com TDD (teste que falha primeiro) e verificados ao vivo.
Gates de cobertura passando: **backend 91,1%** (`mix coveralls`, piso 80) · **web 90,9% stmts /
77,2% branch** (`npm run coverage`).

| # | Correção | Arquivos | Teste |
|---|---|---|---|
| **F1** | `reemitSession` só re-emite a sessão quando a resposta da API **não é erro** (`status < 400`); sucesso do callback é 3xx, falha é 4xx. Link inválido/expirado agora cai em `/entrar?erro=…`. | [web/src/lib/server/api.ts](../web/src/lib/server/api.ts) | `api.test.ts` (401 c/ cookie → null; 302 → re-emite) |
| **F2** | `fetch_clinic_patient`/`fetch_clinic_professional` normalizam id não-UUID para `{:ok, nil}` (→ 404) via `Ecto.UUID.cast`, em vez de deixar o `InvalidArgument` virar 500. | [records.ex](../api/lib/api/records.ex), [directory.ex](../api/lib/api/directory.ex) | testes de controller "id malformado → 404" |
| **F3** | Sidebar esconde a contagem do segmento quando os dados não vieram (`hasPatCounts`/`hasProfCounts`), em vez de mostrar "0". | [Sidebar.svelte](../web/src/lib/components/shell/Sidebar.svelte) | (coberto pelos testes existentes do Sidebar) |
| **F4** | Guard de status de origem (`Validations.StatusIn`, `from:`) em cada transição: `reopen` só de fechado; `justify` só de `faltou`; `complete/miss/cancel` só de aberto. Transição inválida → 422, sem escrita nem trilha fantasma. | [status_in.ex](../api/lib/api/scheduling/appointment/validations/status_in.ex), [appointment.ex](../api/lib/api/scheduling/appointment.ex) | `appointment_test.exs` (describe "guard de status de origem (F4)") |

Verificação ao vivo pós-correção: link lixo → `/entrar?erro=link`; `GET /api/patients/nao-e-uuid`
→ 404; sidebar de `/pacientes/[id]` sem "0"; `reopen`/`justify-absence` sobre um agendado → 422
(status inalterado).

## E2E das páginas internas (logadas) — status

**Não há e2e (browser) das páginas autenticadas.** A suíte Playwright cobre só os caminhos
backend-less do CI: o formulário de login (`login.spec.ts`) e o tema (`theme.spec.ts`). As telas
internas (agenda, pacientes, profissionais, configurações, fila, notificações) são cobertas por
**testes de componente/unidade (Vitest)** no `web/` e pelos **testes de controller** no `api/`,
mas não por e2e ponta-a-ponta no navegador.

Um fixture de e2e autenticado chegou a ser prototipado nesta sessão (login só-dev + `storageState`),
mas foi **descartado por decisão de produto**: rodar e2e logado exige API + banco no job (o job de
e2e do CI sobe só o web), e a cobertura das telas internas via componente/controller foi considerada
suficiente por ora.
