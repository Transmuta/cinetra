# 38 — Bate-volta das Frentes 3 e 4

Auditoria do diff de `50416b8..HEAD` — os commits [`83e0e2a`](../) (Frente 3: canal `block`×`signal`,
cache de fuso, presenças do `after_action`, `SocketRevocation`) e `9d594ff` (Frente 4: motivo do
cancelamento, paginação da fila, vaga reservada, cron em lote). Plano das frentes em
[`35`](35-plano-execucao-backlog.md).

**Onde parou:** rodada 5. A rodada 1 achou duplicação e código morto; a rodada 2 (adversarial, pelo
fluxo real no browser) achou **um bug de correção** que a checklist não pegaria. Três causas
consertadas, todas re-sondadas na app rodando.

---

## 1. A novidade desta rodada: o browser entrou

As duas frentes fecharam com a mesma dívida — "não verificado ao vivo". Nesta rodada o Playwright
MCP entrou, **parcialmente**: `navigate`, `screenshot` e `type` funcionam; **`click`, `snapshot` e
`evaluate` estão quebrados neste build** (o `click` devolve "✅ Clicked element" e não dispara nada
— provado num `<a href>` que não navegou). A verificação foi feita então com **browser para render
+ `curl` com sessão real para as ações**, o que cobriu tudo menos os fluxos que exigem clique.

Receita que funcionou, para a próxima vez:

```bash
# 1. pede o magic link pelo BFF
curl -s -X POST http://localhost:5173/entrar -d 'email=<user>' -H 'content-type: application/x-www-form-urlencoded'
# 2. lê o link do dev mailbox (JSON, não HTML)
curl -s http://localhost:4010/dev/mailbox/json | python3 -c "…"
# 3. abre o link no browser (Playwright) E/OU num cookie jar do curl
curl -s -c jar.txt -b jar.txt -L "<link>"      # jar serve para bater direto no :4010
```

O que a sonda viva provou, e os testes não provavam:

| O que | Prova |
| --- | --- |
| **D-G/D-H: o modo entra no join** | log do servidor: `JOINED clinic:…:agenda:2026-07-22` com `Parameters: %{"mode" => "signal"}` — 7 tópicos, um por dia da Semana |
| **D-G/D-H: o servidor não relê o bloco** | com a Semana aberta, um `POST /api/appointments` por curl; nas queries seguintes **nenhuma** em `patients`/`attendances` — só o `GET /counts` que o sinal disparou |
| **D-G/D-H: a tela reage** | a célula "Qui 23" foi de `0 agend.` para `2 agend.` **sem reload** |
| **F4: o cadeado aparece** | `POST /waitlist/:id/offer` por curl → a linha da fila renderizou o chip cinza com cadeado, "Fulana está oferecendo" no `title` |
| **F4: em tempo real** | com `/fila` **aberta**, a reserva criada por fora fez as três linhas ganharem o cadeado sozinhas (o `slot_held` do notifier) |
| **F6: contagens do servidor** | a sidebar mostrou `Todas 3 · Urgente 1 · Normal 1 · Baixa 1` com a lista paginada |

**Não verificado (precisa de clique):** o diálogo de cancelamento do **F3** e o `S1` (revogação
derrubando socket, que exigiria criar e revogar um vínculo). Os dois têm teste automatizado; o que
falta é o olho humano no render do diálogo.

---

## 2. A varredura

### Segurança ([lista](../.claude/skills/bate-volta/references/seguranca.md))

| Item | Estado |
| --- | --- |
| Bypass do BFF / ataque direto na API | **NÃO SE APLICA** — nenhuma rota nova; `/api/waitlist` já existia e segue sob `:authenticated` |
| Tenant vindo do cliente | **REFUTADO** — `clinic_id` continua saindo só do escopo; os params novos (`limit`/`offset`/`prio`/`mode`) não tocam tenancy |
| IDOR / BOLA (superfície nova: `holds` na lista) | **REFUTADO** por sonda RLS: como `movimento_app` com a GUC da clínica A, `SELECT count(*) FROM slot_holds` da clínica B → **0 linhas** (idem `waitlist_entries`) |
| Function level authorization | **REFUTADO** — `live_holds/1` passa pela policy de `SlotHold`; `entry_counts/1` roda `Ash.Query.for_read(:queued)` com escopo |
| Mass assignment | **REFUTADO** — nenhum `accept` novo; `cancel_reason` já era aceito pela ação `:cancel` |
| CORS / CSRF | **NÃO SE APLICA** — sem endpoint de mutação novo |
| Brute force / enumeração / magic link / OAuth / timing | **NÃO SE APLICA** — o diff não toca autenticação |
| Sessão / revogação | **melhorada** pelo próprio diff (S1); nada a apontar |
| XSS | **REFUTADO** — `cancel_reason` e `held_by.nome` saem por interpolação normal do Svelte (escapada); sem `{@html}` no diff |
| SQL injection | **REFUTADO** — o único SQL cru novo é `DELETE FROM slot_holds WHERE expires_at <= now()`, sem interpolação; a GUC vai por `set_config($1,$2,true)` parametrizado |
| SSRF / open redirect / path traversal | **NÃO SE APLICA** |
| Vazamento de `clinic_id` / em log | **REFUTADO** — o `professional_ids` do evento interno **não** vai para o cliente (o canal monta o payload do push); nada novo em log |
| Secrets em código / headers | **NÃO SE APLICA** |
| DoS (paginação, payload) | **REFUTADO** por sonda viva: `?limit=10000000` → 200, `?offset=999999999` → 100.000, `?limit=abc` → 50 |
| Dependência vulnerável | **NÃO SE APLICA** — `mix.exs`/`package.json` intocados |

### Performance ([lista](../.claude/skills/bate-volta/references/performance.md))

| Item | Estado |
| --- | --- |
| N+1 | **REFUTADO** — `GET /api/waitlist` custa 13 queries com 3 itens; o número não cresce com as linhas (o motor de vagas é em lote desde a E5) |
| Seq scan / plano | **medido** — o `:queued` usa Bitmap Heap Scan pelo índice de `clinic_id` + **Sort em memória** pelo `CASE` do `prio_rank`. Ver "o que ficou para você" |
| Paginação ausente | **corrigido pelo próprio diff** (era o F6) |
| `SELECT *` | **REFUTADO** — `entry_load/0` continua com projeção enxuta; `clinic_ids/0` do worker passou a ler só `:id` |
| Aggregate caro | **medido** — `entry_counts/1` é **uma** query com 5 counts |
| Índice de FK | **NÃO SE APLICA** — nenhuma FK nova (nenhuma migration no diff) |
| Índice de filtro | ver "o que ficou para você" (o `prio_rank` não é indexável como está) |
| Pool / transação longa | **REFUTADO** — o lote do cron é uma transação de N `DELETE`s numa tabela quase vazia; sem I/O externo dentro |
| Crescimento sem poda | **REFUTADO** — `slot_holds` tem o cron; o cache de fuso é 1 entrada por clínica |
| Front (waterfall, bundle) | **REFUTADO** — `/fila` segue com `Promise.all`; o `Lock` é import de símbolo |

### Refatoração ([lista](../.claude/skills/bate-volta/references/refatoracao.md))

| Item | Estado |
| --- | --- |
| Lógica duplicada | **CONFIRMADO** — clamp de paginação em 3 módulos; `parse_int` em 3 controllers (causa 2) |
| Contratos divergentes | **CONFIRMADO** — a cópia nova do `parse_int` aceitava negativo; as outras duas não |
| Constante repetida | **CONFIRMADO** (parcial) — `50` como tamanho de página em 4 lugares no backend e 3 no web |
| Regra fora da action | **REFUTADO** — o filtro `?prio` saiu do cliente **para** o servidor; é o movimento certo |
| Duplicação em teste | **REFUTADO** — os testes novos reusam `fixture`/`ConnCase` |
| Comentário mentiroso | **CONFIRMADO** — dois comentários diziam que a fila "filtra no cliente / não é paginada" (causa 3) |
| Código morto | **CONFIRMADO** — `sortByPriority` ficou sem uso (causa 3) |
| Elixir (pattern matching, erros, armadilhas, nomes) | **REFUTADO** — `String.to_existing_atom` do `prio` é precedido de whitelist; sem `case` aninhado novo |
| Ash (policies, code interface, calculations) | **REFUTADO** — `prio_rank` é calculation (não Ecto na mão); `page_waitlist_entries` é code interface |
| OTP | **REFUTADO** — `ClinicTimezone` trata só as mensagens que assina; estado vazio |
| Front (TS, runes, fronteira) | **REFUTADO** — `svelte-check` limpo, sem `any` novo |
| Docs/saída | **REFUTADO** — este relatório é arquivo local, como manda o CLAUDE.md |

**O que a rodada 2 achou que a 1 não tinha achado:** a **causa 1** — o descasamento de janela entre
a lista e o motor de vagas. Nenhum item de checklist perguntaria isso; ela apareceu ao seguir o
fluxo real ("a tela pede duas coisas; as duas concordam?").

---

## 3. As causas-raiz

### Causa 1 — duas chamadas, uma janela só (correção) 🔴

A tela da fila faz **duas** requisições: a lista (`GET /api/waitlist`) e as vagas
(`GET /fila/slots`). O F6 ensinou a janela (`limit`/`offset`) às duas, mas o **filtro** (`?prio=`),
que também saiu para o servidor na mesma frente, só foi para a primeira. Resultado: a lista mostra
um recorte e o motor calcula o outro.

Sonda que achou (API real, fila com 3 itens):

```
tela  (?prio=baixa&limit=1&offset=0) → entry …76e27f  (baixa)
motor (?limit=1&offset=0, sem prio)  → vagas de …1979b9  (urgente)
```

Na tela: a linha filtrada aparece **sem chip de vaga** (e com o marcador "sem vaga compatível",
que é falso). Só se manifesta quando o item filtrado está além dos 50 primeiros da fila
não-filtrada — ou seja, exatamente no volume para o qual a paginação foi feita.

### Causa 2 — a terceira cópia da mesma regra de paginação (DRY) 🟡

Três domínios paginam (`Api.Records`, `Api.Scheduling`/auditoria, `Api.Waitlist`) e cada um tinha
escrito a mesma regra: 50 padrão, teto 200, teto de offset 100k. A Frente 4 **acrescentou a
terceira**, com forma própria (`clamp/4` genérico em vez de cláusulas). O mesmo na fronteira:
`parse_int/1` byte a byte igual em dois controllers, e a cópia nova (`inteiro/1`) **já divergia** —
aceitava negativo.

### Causa 3 — o que a mudança deixou para trás (limpeza) 🟢

Ao mover ordenação e filtro para o servidor, `sortByPriority` ficou sem chamador e dois comentários
passaram a descrever o passado como presente ("a fila é bounded — filtra-se no cliente", "não
paginada").

---

## 4. O que foi corrigido

| Causa | Teste vermelho | Conserto | Re-sonda (rodada 5) |
| --- | --- | --- | --- |
| **1** | `slots/server.test.ts`: "repassa o filtro de prioridade junto da janela" — falhou com `expected { limit: 50, offset: 0 } to deeply equal …prio` | o endpoint `/fila/slots` lê `?prio=` e repassa; a tela o inclui na URL do `fetch` | mesma sonda, agora pelo BFF: tela `…76e27f` / motor `…76e27f` ✅ |
| **1** (lado do cliente) | `fila/page.svelte.test.ts`: "pede as vagas com o mesmo filtro da lista" — **provado por mutação** (removi o `prio` da URL: vermelho) | idem | suíte web 1178/0 |
| **2** | — (refactor com teste de caracterização novo: `pagination_test.exs`, 4 doctests + 11 testes) | novo `Api.Pagination` (limit/offset/page_opts) usado pelos três domínios; `parse_int/1` movido para `ApiWeb.TenantScope` e usado pelos três controllers | `curl` na app: `?limit=abc`→50, `?limit=10000000`→200, `?offset=999999999`→100000 ✅ |
| **3** | — | `sortByPriority` e seus testes removidos; os dois comentários reescritos | `svelte-check` 0 erros; grep sem referências órfãs |

Verde ao fim: api **786/0** (4 doctests), gate RLS **7/0**, web **1178/1178**, `svelte-check` **0**.

---

## 5. O que ficou para você

### A. O `prio_rank` ordena em memória, sem índice — **estrutural**

**O que é.** A ordem da fila (`urgente → baixa`, depois tempo de espera) é um `CASE` no `ORDER BY`.
Com `OFFSET`, o Postgres ordena **todas** as linhas da clínica antes de recortar a página.

**A sonda** (como `movimento_app`, com a GUC da clínica):

```
Limit  (cost=9.55..9.56 rows=2)
  ->  Sort  (cost=9.55..9.56 rows=2)
        Sort Key: (CASE WHEN (prio = 'urgente') THEN 0 … END), inserted_at
        Sort Method: quicksort  Memory: 25kB
        ->  Bitmap Heap Scan on waitlist_entries
              Recheck Cond: (clinic_id = current_setting('movimento.clinic_id', true)::uuid)
```

**Por que não foi corrigido.** A fila é bounded por natureza (pacientes esperando encaixe) e o
custo hoje é 0,04 ms. A correção — índice de expressão `(clinic_id, CASE …, inserted_at)` — tem a
armadilha que o [`35`](35-plano-execucao-backlog.md) já documentou no D-A: **índice de expressão só
anexa se a expressão bater byte a byte com o SQL que o Ash emite**, e o AshPostgres injeta casts.
Fazer isso sem medir pelo caminho da aplicação repetiria o erro que aquela frente pagou.

**Qual seria a correção.** Ou o índice de expressão (medido por `pg_stat_user_indexes` com a query
saindo do `list_entries`), ou uma coluna `prio_rank` materializada por change — que troca custo de
leitura por invariante a manter.

### B. O `countable: true` da fila conta a cada request — **mesma classe do D-Aud1**

**O que é.** A leitura paginada da fila faz um `COUNT(*)` do recorte por request, para o "X–Y de Z".
É o mesmo padrão que o [`30 §4`](30-decisoes-pendentes-agenda.md) registrou como **D-Aud1** na
auditoria.

**A sonda.** `GET /api/waitlist` emite 3 queries em `waitlist_entries`: a página, o `COUNT(*)` e o
agregado das contagens.

**Por que não foi corrigido.** Diferente da trilha de auditoria (que é a tabela que mais cresce), a
fila é bounded — e o D-Aud1 está **bloqueado por decisão de produto** (a semântica do rótulo). Se a
decisão for tomada, ela vale para as duas telas de uma vez.

### C. O chip de disponibilidade transbordava a coluna — ~~pré-existente~~ **CORRIGIDO**

**O que era.** Na `/fila`, o chip de disponibilidade ultrapassava a coluna e cobria o texto de
"Profissional".

**A sonda.** Screenshot com a reserva (chip + cadeado) e **sem** ela: transbordava nos dois casos —
o cadeado do F4 agravava ~11 px, não causava. Defeito anterior ao diff auditado.

**A causa.** Item de grid tem `min-width: auto`: ele **não encolhe abaixo do conteúdo**. Com
`whitespace-nowrap` dentro do chip, o conteúdo mínimo é o chip inteiro — então ele estourava a
faixa `minmax(200px, 2fr)` e pintava por cima da vizinha.

**O conserto** (a pedido, depois do relatório): `min-w-0` na célula, `max-w-full` + `truncate` no
chip, e no chip de vaga o que encolhe é o **rótulo da regra** — a data e a hora ficam inteiras,
porque são a informação que faz a pessoa clicar. O texto completo continua no `title`.

**Scroll horizontal foi descartado** como alternativa: a coluna de ações (Oferecer/editar/excluir)
é a última, e seria a primeira a sumir atrás do scroll; a lista já troca para **cartão** abaixo de
`md`, que é a resposta certa para tela estreita; e nenhuma outra lista do projeto (Pacientes,
Membros) rola na horizontal — o padrão é truncar com `title`.

**Provado ao vivo:** com a mesma reserva do §1, o chip virou `🔒 Seg/Ter/Qua/… sex 24/07 08:00` e a
coluna "Profissional" voltou a mostrar "Qualquer" legível.

### D. ~~`release_slot_hold` não tem rota HTTP~~ — **resolvido por remoção**

**O que era.** O domínio tinha a ação de soltar a reserva e o router não a expunha: fechar o modal
de "Oferecer" não liberava a vaga, que ficava presa por 10 minutos.

**O que aconteceu depois.** Ao levar isto ao humano, a pergunta certa apareceu — *"por que essa
trava existe?"* — e a sonda seguinte mostrou que a UI **nunca criava reserva nenhuma**
(`git log -S'?/oferecer' -- web/src` → vazio). A reserva inteira foi removida e o aviso virou
presença efêmera. Ver [`39`](39-fila-sem-reserva-de-vaga.md).

**A lição.** O handoff estava certo em apontar o sintoma e errado em enquadrá-lo: eu tratei como
"falta uma rota" o que era "sobra um mecanismo". Perguntar *se a peça precisa existir* vem antes
de perguntar *como consertá-la*.

### E. Playwright MCP com `click`/`snapshot`/`evaluate` quebrados — **ferramental**

**O que é.** Este build do MCP responde "✅ Clicked element" sem clicar (provado num `<a href>` que
não navegou), e `snapshot`/`evaluate` estouram (`Cannot read properties of undefined`,
`Illegal return statement`).

**Consequência.** Fluxos que exigem clique — o diálogo do F3, o arraste da agenda ([`30 §2`](30-decisoes-pendentes-agenda.md)),
qualquer modal — continuam sem verificação de browser. A receita do §1 cobre o resto.
