# 28 — Auditoria bate-volta: o tempo real da agenda (Entrega 3)

Auditoria do diff da **Entrega 3 — tempo real** (WebSocket/Channels da agenda) contra a stack
rodando. Cinco rodadas: duas de caça (checklist + adversarial, despachadas em paralelo aos três
eixos), consolidação, conserto e verificação. A regra do método: **nenhum achado sem o output
de uma sonda** — `psql` como `cinetra_app` (RLS real), `mix test`, `iex`, `curl`, `EXPLAIN`,
`docker compose logs`, e o Playwright no navegador.

## 1. Onde parou, e por quê

Parou na **rodada 5 com três consertos aplicados**. A caça achou **1 defeito de correção**
(a visão Semana não atualizava em tempo real), **1 corte de performance** no caminho recém-quente
e **1 resíduo cosmético**. O eixo de **segurança fechou sem nenhum achado** — o risco central
(vazamento de tenant por um socket que não passa por RLS nem policy) está provado fechado três
vezes independentes. O resto é decisão humana: performance estrutural (a releitura por assinante,
já documentada como R-D1) e dívida pré-existente.

Gates ao fim: **backend 560 testes / 90,4%**, **web 890 testes / 93,4%** (`+2` do predicado novo),
`mix format` e `svelte-check` limpos.

## 2. A varredura

Três caças em paralelo (`quality-specialist` / `data-engineer` / `test-engineer`), cada uma
checklist + adversarial no seu eixo.

### Segurança — por classe de ataque

| Classe | Estado | Prova |
| --- | --- | --- |
| Bypass do BFF / ataque direto na API | SEGURO | `curl` sem cookie em `:4010/api/realtime/token` → **401** (rota sob `:authenticated`) |
| Tenant vindo do cliente | SEGURO | `clinic_id` do tópico conferido por **igualdade exata de byte** contra o do token; case/espaço diferente → `:error` |
| BOLA / IDOR (o risco central) | SEGURO | `load_visible_appointment` cross-tenant → `nil`; RLS `cinetra_app` → **0 linhas**; A7 (colega) → `nil` |
| Function-level authz | SEGURO | `join` com 2 guardas (same_clinic + membership relido do banco); `handle_info` relê pela read com policy |
| Mass assignment | N/A | `connect` só aceita `"token"`; `join` ignora `_params` |
| CSRF / CSWSH | SEGURO | auth por **bearer token**, não cookie de ambiente; `check_origin: [web_app_url]` em prod |
| Revogação de sessão | PARCIAL → §5 R1 | barrada no `join` (relê banco); janela em socket **já aberto** (Entrega 4) |
| XSS | N/A | nenhum `{@html}` novo; push serializa via `AgendaJSON`, Svelte escapa |
| Vazamento em log/query string | PARCIAL → §5 R2 | BFF devolve corpo genérico; token viaja na query string do WS (900s) |
| CSP | SEGURO | `connect-src` com hosts **fixos**, sem `ws:`/`wss:` genérico (§5 R3: host de dev na CSP única) |
| Dependência vulnerável | SEGURO | `phoenix ~1.8` + `@types/phoenix`; `npm audit --omit=dev` → 0 |

### Performance — query e indexação

| Item | Estado | Prova |
| --- | --- | --- |
| N+1 na releitura | REFUTADO (por chamada) / o "N" são **assinantes** | reread = 6 queries (attendances batcheado); fan-out por assinante → P1 |
| Seq scan sem índice | CONFIRMADO (pré-existente) | `:in_range` — `ends_at > from` cai em `Filter`, nunca `Index Cond` → P3 |
| `SELECT` de colunas a mais | CONFIRMADO | `patients_for` trazia **39 colunas** p/ serializar 4 → **corrigido** (§4) |
| Índice de FK faltando | N/A | Entrega 3 não tem migration |
| `invalidate` reexecuta load caro | CONFIRMADO (interação) | sinal do Mês → `invalidate` → refetch → scan do P3 → P4 |
| Waterfall de `fetch` no cliente | REFUTADO | token 1×/aba; conexão depende de `topicsKey`, não de `data` |

### Refatoração — DRY e rules

| Item | Estado | Prova |
| --- | --- | --- |
| `AgendaJSON` fonte única, sem duplicação | REFUTADO (limpo) | controller e canal serializam pela **mesma** `AgendaJSON.appointment/1`; grep não achou mapa à mão |
| `RealtimeToken` fonte única do salt/validade | REFUTADO (limpo) | grep `"realtime socket"`/`900` → só `realtime_token.ex`; assina e verifica leem dele |
| `Ash.get!/read!/load!` cru nas peças novas | REFUTADO (limpo) | canal só usa code interfaces (`get_user`, `get_active_membership`, `load_visible_appointment`) |
| `with`/pattern matching, sem case aninhado | REFUTADO (limpo) | `join` é um `with`; notifier é tudo cabeça de função |
| TDD: código novo tem teste | REFUTADO (limpo) | 21 back + 24 web verdes cobrindo canal/socket/notifier/patch/token |
| Contrato de tópico casado cliente↔servidor | REFUTADO (com nota) | pinado dos dois lados; divergência falharia **fechado** (`invalid_topic`) |
| `_scope` vestigial em `render_appointment/2` | CONFIRMADO (cosmético) | **corrigido** (§4) |

### O que a rodada 2 (adversarial) achou que a checklist não pegou

O achado que motivou os consertos **não estava em nenhuma checklist** — veio de seguir o fluxo
real no navegador com duas sessões. O `data-engineer`, ao rastrear o caminho do sinal, notou que
a visão Semana assina tópicos de **dia** (recebe bloco cheio) mas renderiza `data.days`
(contagem), e marcou como "cheira a bug de tempo real, mas é correção, não performance". Ao vivo
confirmou-se **defeito**, e virou o Conserto 1.

## 3. As causas-raiz

**A. A Semana confundia bloco com contagem (correção).** O cliente roteava **todo** evento de
tópico de dia para `onAppointment` (remendo em `live.appointments`). Mas a Semana renderiza
barras de ocupação (`data.days`), não a lista de blocos — então o remendo caía num store que ela
não mostra, e a barra ficava congelada. Só o Mês atualizava, porque assina o tópico de **mês**,
que emite `agenda_changed` → refetch. A causa é uma: **a resolução bloco-vs-sinal é por-tópico
(dia=bloco, mês=sinal), e a Semana é o caso que não se encaixa — tópico de dia, mas quer sinal.**

**B. `patients_for` carregava o cadastro inteiro (performance + PII).** A releitura do canal
(`load_visible_appointment/2`, nova) passa por `patients_for`, que trazia as ~39 colunas do
paciente — CPF, RG, `prefs` — para serializar 4. Antes era 1× por request; agora é **por
assinante por evento**. É o mesmo corte que o doc 27 (Causa 2) fez em `load_counts` e que ficou
de fora daqui.

**C. `_scope` vestigial (cosmético).** Pós-extração do `AgendaJSON`, `render_appointment/2`
delegava numa linha mas manteve o `_scope` que ninguém lê.

## 4. O que foi corrigido

### Conserto 1 — a Semana atualiza em tempo real (correção, ALTA)

**Sonda que achou (ao vivo, 2 sessões):** na Semana, criando um agendamento pela sessão do
profissional (`curl` com cookie jar próprio) na sessão do owner (navegador):

```
antes do conserto:  "Seg 20 · 6 agend. · 28% ocupado"   (criei o 7º)
tela ao vivo:       "Seg 20 · 6 agend. · 28% ocupado"   ← NÃO mexeu
após refresh manual:"Seg 20 · 7 agend. · 32% ocupado"   ← o servidor tinha 7
```

A contagem mudou no servidor; o tempo real não a refletiu.

**Teste vermelho:** `viewRendersCounts is not a function` (`agenda-views.test.ts`) — o predicado
puro que decide entre remendar (Dia/Lista) e recarregar (Semana/Mês).

**Conserto:** `viewRendersCounts/1` em `agenda-views.ts` (a casa da semântica de visão), e no
`+page.svelte` o `onAppointment` recarrega em vez de remendar quando a visão é de contagem — o
mesmo caminho que o sinal do Mês já tomava.

**Re-sonda (rodada 5, ao vivo):**

```
baseline:  "Seg 20 · 8 agend. · 37%"
criei o 9º pela sessão do profissional
tela ao vivo, SEM refresh:  "Seg 20 · 9 agend. · 42%"   ← atualizou sozinha
```

Dia (o caminho de remendo) reconferido no mesmo passe: blocos continuam entrando por patch, sem
regressão, zero erro de console.

### Conserto 2 — `patients_for` com `select` enxuto (performance/PII, BAIXA-MÉDIA)

**Sonda que achou:** log da 5ª query da releitura — `SELECT p0."complemento", p0."rg", … p0."cpf",
… p0."prefs", … (39 colunas) FROM "patients"`.

**Conserto:** `query: [filter: …, select: [:id, :nome, :tel, :ativo]]` em `patients_for`.

**Re-sonda (rodada 5):** log da mesma leitura da agenda depois do conserto:

```
p0."id" p0."nome" p0."ativo" p0."tel" p0."clinic_id" p0."inserted_at"   → 6 colunas
```

De 39 para 6 (os 4 usados + `clinic_id` para a RLS + `inserted_at` para o sort default). CPF, RG
e `prefs` deixaram de trafegar. Vale para as duas portas (o `GET` e o push) porque `patients_for`
serve as duas.

### Conserto 3 — `_scope` vestigial removido (refatoração, cosmético)

`render_appointment/2` → `render_appointment/1`; os 2 call sites deixaram de passar `scope`.
`scope` segue usado no `render_range` (para `load_agenda` e `scope.now`).

**Verificação:** `appointments_controller_test` (55 testes com os canais) verde; `mix format`
limpo.

## 5. O que ficou para você

Nada aqui é conserto óbvio — é performance estrutural (decisão de arquitetura) ou dívida
pré-existente. Ordenado por relevância.

### (a) A releitura por assinante — 6 queries × N assinantes por escrita (P1, MÉDIA, estrutural)

**O que é:** `AgendaChannel.handle_info` chama `load_visible_appointment/2` por assinante do
tópico afetado. É a decisão **R-D1** documentada ("ao custo de uma leitura por assinante por
escrita"), e é o que garante o recorte A7 no push sem reimplementar o filtro. Escala com
**espectadores concorrentes**, não com dados.

**Sonda:** por escrita = `1 (notifier) + Σ_assinantes × (6 ou 4)` queries, cada releitura abrindo
1 transação → consome 1 conexão do `pool_size: 10`. Uma clínica com ~15 recepção/admin no mesmo
dia ≈ 90 queries e 15 checkouts contra 10 conexões por agendamento criado.

**Por que não foi corrigido:** é a arquitetura da fatia, não um bug. **A correção certa ficou mais
atraente depois do Conserto 1:** com a Semana recarregando (não remendando), só Dia e Lista
precisam do bloco cheio — Semana e Mês só precisam de um sinal. Se o `join` recebesse a
resolução do assinante como parâmetro (`block` vs `signal`), o canal mandaria sinal leve aos
assinantes de contagem **sem reler o bloco**, matando a releitura desperdiçada de uma vez (fecha
também o P2 abaixo). É redesenho do contrato do canal → decisão sua.

### (b) O assinante do Mês paga a releitura e a descarta (P2, BAIXA-MÉDIA)

`handle_info` relê **antes** de ramificar por resolução; o push do Mês casa `{:month,_}` e
descarta o `_visivel`, empurrando só `%{day, change: "count"}`. Sonda: 6 queries para produzir um
sinal de 2 campos. Dobra no redesenho de (a) — resolvê-los juntos é o certo.

### (c) `:in_range` varre o histórico da clínica (P3/P4, ALTA em escala, pré-existente)

`ends_at > from` (o limite inferior da janela) não está em índice nenhum → sempre `Filter`. O doc
27 (a) já mediu: **40.000 linhas lidas para devolver 638**. A Entrega 3 não introduziu, mas o
**torna repetível por evento** (P4): cada aba em Semana/Mês dispara uma varredura por evento (o
debounce de 400 ms coalesce rajadas). A correção (teto de duração ou índice GiST não-parcial) é a
mesma decisão de arquitetura já registrada no doc 27 (a).

### (d) `load_clinic` por escrita no notifier (P6, BAIXA)

`AgendaNotifier.local_date/1` chama `get_clinic!` a cada escrita para o fuso (1 PK-hit, 2
buffers). Sem camada de cache de configuração. Evitável (cachear o fuso em `persistent_term`, com
invalidação no `update_clinic_info`), mas é 1 query por **escrita**, não por assinante — marginal.

### (e) Resíduos de segurança (BAIXA/informativo)

- **R1 — revogação não alcança socket já aberto.** Barrada no `join` (relê o vínculo); um socket
  **já aberto** segue recebendo eventos da própria ex-clínica até desconectar/rejoin. O
  isolamento de tenant **não** quebra. Fix previsto: `Endpoint.disconnect/1` no sign-out
  (Entrega 4 — `user_socket.ex` já nasce com `id/1` por usuário para isso).
- **R2 — token na query string do WS.** Bearer visível em log de proxy; mitigado pela vida de
  900 s (trade-off aceito no doc 09 §8).
- **R3 — host de dev na CSP de prod.** `svelte.config.js` inclui `localhost:4010` na CSP única de
  build. Inexplorável em prod, mas o `connect-src` de prod carrega origem de dev. Fix opcional:
  derivar os hosts por ambiente no build.

### (f) Dívida de refatoração (BAIXA, pré-existente)

- **`/api/realtime/token` buscado em dois lugares no cliente** (`realtime.ts` renovação vs
  `+page.svelte` config inicial) — um `fetchRealtimeConfig()` unificaria. Ambos testados.
- **Boilerplate de `sign_in`/`fixture` de magic link** replicado em 20 arquivos de teste (2 novos
  seguiram o padrão vigente). A correção é um `Ash.Generator`/`AuthCase` de projeto, não de fatia.

## 6. Verificação final

- Backend: `MIX_ENV=test mix coveralls` → **560 testes, 0 falhas, 90,4%**.
- Web: `npm run coverage` → **890 testes, 0 falhas, 93,4% stmts** (`+2` do predicado).
- `mix format --check-formatted` → limpo. `npm run check` → 0 erros/0 warnings.
- Conserto 1 re-sondado **ao vivo** (Semana atualiza sem refresh; Dia sem regressão).
- Conserto 2 re-sondado por **log de query** (39 → 6 colunas).
- Segurança re-provada: RLS `cinetra_app` (NOBYPASSRLS) → 0 linhas cross-tenant; `curl` sem
  cookie → 401; A7 no push → `nil`.
- **Nenhuma escrita destrutiva foi executada** pelas sondas; os agendamentos criados na
  verificação ao vivo foram criações legítimas pela própria action, na clínica de demo.
