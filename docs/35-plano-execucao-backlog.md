# 35 — Plano de execução do backlog (Ondas)

Consolidação **acionável** do que foi adiado/deferido e priorizado para execução. As fontes de
verdade dos itens continuam sendo [`08-roadmap.md`](08-roadmap.md),
[`30-decisoes-pendentes-agenda.md`](30-decisoes-pendentes-agenda.md),
[`33-relatorios.md`](33-relatorios.md) e os bate-voltas; este doc só **agrupa e sequencia** a
seleção aprovada, em frentes coesas por trilha de código + dependência.

Natureza do bloqueio: **[P]** decisão de produto · **[T]** técnico/arquitetura · **[P+T]** ambos.

> ## ▶︎ Onde retomar
>
> **Onda 1 está feita. A Frente 2 está PARCIAL** — o bate-volta reprovou e reverteu o **D-A**
> (índice que nunca anexava) e removeu o **D-S** (seed sem guarda que ia para a imagem de prod).
> Ver "Status de execução" abaixo, e "D-A — o diagnóstico correto" antes de tentar de novo.
>
> **As Frentes 3 (tempo real & escrita) e 4 (fila & holds) estão FEITAS** — ver o status abaixo.
> Com isso a **Onda 2 fecha**, exceto o D-A da Frente 2, que o bate-volta devolveu ao backlog.
> Próximo passo: **Onda 3 — Frente 5 (Pacotes/A1)**, que é o caminho crítico.
>
> A recomendação de **verificar antes de codar** se confirmou de novo: na Frente 3, **2 dos 6
> itens já estavam prontos** (D-Q e D-N) — 7 no acumulado das três frentes. O doc 30 envelheceu;
> confira cada item no código antes de abrir editor.
>
> Duas lições da leva anterior, que continuam valendo: **medir pelo caminho da aplicação**, nunca
> por SQL escrito à mão; e **provar que o teste morde** (mutação), porque teste verde não é rede.
> A Frente 3 seguiu a primeira (as medições saíram do `Api.QueryCounter`, no caminho real) e
> deixou a segunda **pendente** — os tetos novos não foram testados por mutação.

## Fora desta rodada (deferidos de novo, conscientes)

Registro para não parecerem esquecidos — **não** entram nas ondas abaixo:

- **F1** (quem-cabe UI), **F7** (confirmar/iniciar) e **F8** (eliminação LGPD) — não selecionados.
  (**F4** *está* no escopo: é da Frente 4.)
- **D-B** (mês pede o mês, não a grade) → dias da grade fora do mês seguem sem contagem.
- **D-I** (cascata N+1 da turma) → transição de turma segue 3N escritas (bounded pela capacidade).
- **S4** (hold aceita profissional arquivado) → inofensivo, barrado na conversão.
- **Relatórios follow-ups** (intervalo custom, snapshot Oban) e **membros hardening** (B/C) —
  não selecionados.
- **v2 inteiro**: prontuário, faturamento/repasse, salas/recurso, multi-unidade, cifra do CPF.

## Itens que ficam PARCIAIS pela própria seleção

- **C13 (ficha):** só saem do oculto **Pacotes** (pós-A1) e **Histórico** (attendances já
  existem). **Anexos** dependem do prontuário v2 → seguem ocultos. `faltas` depende de F1.
- **F#51 (lembretes cron):** "resumo diário" e "sessão em 15 min" entram; **"paciente não
  confirmou" depende de F7** (fora) → não entra.

## Gates de decisão de produto (resolver ANTES da frente)

1. **A2 (Turma):** presença individual é requisito? + bug do `pkgOf` (ajuste em massa
   multi-pacote). *Muda schema.* — bloqueia Frente 6.
2. **A3 (futureConflicts):** estender D12 (horário do profissional) para clínica/exceção + o
   terceiro consumidor esquecido (`addHoliday`). — bloqueia Frente 8.
3. **F#48:** limiar de "paciente urgente entrou na fila". — bloqueia esse gatilho na Frente 10.
4. **D-Aud1:** semântica do rótulo "X–Y de Z" (reltuples / `countable:false`+limit+1 / contar
   só com filtro). — bloqueia Frente 12.

---

## As frentes

### Frente 0 — Enablers de medição 🟡 PARCIAL
- **D-M** ✅ — subconjunto `@tag :rls` rodando como `movimento_app` (NOBYPASSRLS); o gate do CI
  estava quebrado e passou a morder (provado por mutação). **[T]**
- **D-S** ❌ **removido** — o seed foi escrito e semeou o dev, mas ia embarcado na imagem de
  produção sem guarda de ambiente. O dado de volume permanece no `movimento_dev`; o gerador,
  se voltar, tem de nascer fora de `priv/`. **[T]**

### Frente 1 — Quick wins / higiene ✅ FEITA
- **I69** — comentário stale em [`nav.ts`](../web/src/lib/components/shell/nav.ts).
- **H60** / **D-T** — bumps `@sveltejs/kit` (cookie ≥ 0.7) e `mint` (CVEs).
- **H61** — paralelizar o BFF. *(O `loadPings` do doc 13 §G não existe mais; o waterfall real
  era `loadMe` → `fetchUnreadCount` no layout do app.)*
- **D-E** / **D-F** — índices FK (`created_by_id`; btree próprio de `professional_id`).
- **D-P** — política DST: **empurra no gap / primeira ocorrência no ambíguo** + teste com tz DST.

### Frente 2 — Performance de leitura da agenda 🟡 PARCIAL (D-A revertido)
- **D-C** — paginar o `:in_range`. **Antes da Fatia 3** (Pacotes reusa o read com janelas maiores).
- **D-A** ❌ **revertido pelo bate-volta** — o índice nunca anexava (cast). Volta ao backlog; ler
  "D-A — o diagnóstico correto" antes de tentar de novo.
- **D-D** — `/api/availability`: remover sonda duplicada, carregar fontes 1×/janela, aceitar
  `professional_id` múltiplo, devolver `timezone` no `/auth/me`.

### Frente 3 — Tempo real & escrita ✅ FEITA
- **D-G + D-H** — contrato do canal (`block` vs `signal` no join): Semana/Mês só recarregam contagem.
- **S1** — revogação desconectar sockets já abertos da ex-clínica.
- **D-K** — cachear fuso da clínica em `persistent_term`, invalidar no `update_clinic_info`.
- **D-J** — devolver attendances do `after_action` (mata o round-trip pós-commit).
- ~~**D-Q** — memoizar `memberships`/papel por request.~~ **JÁ ESTAVA FEITO** (resolvido pelo
  `LoadScope` + `Api.Accounts.ActiveMembership`), com teste de contagem de queries próprio em
  `appointments_controller_test.exs` ("a membership é resolvida uma vez por request").
- ~~**D-N** — unificar a autoridade do recorte (escrita vs leitura) numa fonte só.~~ **JÁ ESTAVA
  FEITO** — leitura e escrita já entravam pelo mesmo `Api.Accounts.ActiveMembership`.

### Frente 4 — Fila de espera & holds ✅ FEITA
- **F3** — `cancel_reason` na UI. **F4** — indicador ao vivo "alguém oferecendo esta vaga".
- **F6** — paginação da fila. **D-L** — Oban cron O(clínicas)/min → statement único.

### Frente 5 — Pacotes (Fatia 3) *(depende de D-C)* ← **PRÓXIMA**
- **A1** — `computeSerie` (domínio puro + Oban), débito com falta punitiva, pausar/retomar
  reprojetando p/ futuro (GAP-06). **Precede A2, C13, notificação #47.** **[T]**

### Frente 6 — Turma (Fatia 5) *(depende de A1 + gate #1)*
- **A2** — presença + débito por participante; resolver o bug do `pkgOf`. **[P+T]**

### Frente 7 — Ficha do paciente (C13, parcial) *(depende de A1)*
- **C13** — destravar abas **Pacotes** e **Histórico** (Anexos ficam ocultos).

### Frente 8 — futureConflicts (Fatia 7, A3) *(gate #2)*
- **A3** — ligar o motor `ImpactAnalysis`/`futureConflicts` ao editar horários. **[P]**

### Frente 9 — Realtime "quem está vendo este dia" (F5)
- **F5** — `Phoenix.Presence` por dia (feature nova, isolada).

### Frente 10 — Notificações
- **Perf/estrutura:** #52 `who_fits` síncrono → Oban; #53 `mark_all_read` via `Ash.bulk_update`;
  #54 LIMIT/paginação + poda/expurgo; #55 índice `[clinic_id, recipient_id, inserted_at desc]`.
- **Gatilhos:** #46 `:faltou`; #47 `participant_added` *(pós-A2)*; #48 urgente na fila *(gate #3)*;
  #50 papel alterado/membro removido; #51 resumo diário + "sessão em 15 min"; #56 deep-link fino.

### Frente 11 — Endurecimento de produção
- **H59** — cookie `secure`, CSP/HSTS/X-Frame, sign-out via POST (CSRF).
- **S3** — hosts da CSP por ambiente (tira `localhost:4010` de prod). **S2** — token no WS via
  header/subprotocol. **H64** — semântica de `ON DELETE` por relação.

### Frente 12 — Auditoria (perf) *(gate #4)*
- **D-Aud1** — corrigir o `COUNT(*)`. **D-Aud2** — índice quando a tela expuser o filtro por autor.

### Frente 13 — Refactors / limpeza
- **I67** — extrair `ApiWeb.ScopeGuards`, `sign_in`/`authed` → `ConnCase`, `in_clinic/2`, contrato
  de paleta. **D-U** — DRY fila↔agenda. **D-R** — pool_size vs fan-out (o dado de volume segue no `movimento_dev`). **I66** —
  e2e do `switch-clinic` + fila/WS não-vazio. **I68** — `goPage` `replaceState` (UX Pacientes).

---

## Ordem sugerida (ondas)

| Onda | Frentes | Estado | Por quê |
|---|---|---|---|
| **1 — Fundação** | 0, 1 | 🟡 Frente 1 feita; Frente 0 parcial (D-S removido) | Enablers de medição + higiene barata destravam e iluminam o resto |
| **2 — Perf & tempo real** | 2, 3, 4 | 🟡 Frentes 3 e 4 feitas; Frente 2 parcial (**D-A revertido**, volta ao backlog) | Mensuráveis com a Onda 1; mesma trilha de código |
| **3 — Valor central** | 5 → 6 → 7 | pendente | Pacotes → Turma → Ficha, sequencial por dependência |
| **4 — Notificações** | 10 | pendente | Perf antes dos gatilhos; #47 só depois da Onda 3 |
| **5 — Produção** | 11 | pendente | Antes do primeiro deploy real |
| **6 — Soltas + limpeza** | 8, 9, 12, 13 | pendente | Features isoladas, auditoria e refactors por último |

**Caminho crítico:** D-C → A1 (Pacotes) → A2 (Turma) → C13/#47.

---

## Decisões da Onda 1 (registradas)

- **D-S:** seed **idempotente repetível**, versionado no repo, numa clínica de teste dedicada;
  não toca dados existentes.
- **D-M:** subconjunto marcado **`@tag :rls`** rodando como `movimento_app`; resto da suíte segue
  como `postgres`.
- **D-P:** **empurra no gap / primeira ocorrência no ambíguo** (determinístico, silencioso).
- **Entrega:** commits pequenos **direto na `develop`** (sem branch/PR nesta onda).

## Status de execução (2026-07-23)

> **Aviso importante: o [`30`](30-decisoes-pendentes-agenda.md) está parcialmente desatualizado.**
> Vários itens que ele lista como abertos **já haviam sido resolvidos** em fatias posteriores —
> em boa parte pelo commit `0a07f4c` ("liquida as pendências do doc 26"). Confirme no código
> antes de reabrir qualquer item daquele doc. Já verificados como **feitos**: D-E, D-P, H60,
> D-D, D-Q, **D-N**.

### Onda 1 — COMPLETA

| Item | Estado |
| --- | --- |
| **D-M** | Gate de RLS do CI **estava quebrado** (apontava para `api_test`); consertado e provado verde (7 testes `:rls` como `movimento_app`) |
| **D-T** | `mint` 1.9.1→1.9.3 — fecha CVE-2026-58229 (DoS) e CVE-2026-59249 (smuggling) |
| **H61** / **I69** | BFF paralelo (`Promise.all`) / comentário do rail |
| **D-E**, **D-P**, **H60** | **já estavam feitos** — confirmados, sem ação |
| **D-F** | Índice btree `appointments.professional_id` |

### Frente 2 (performance de leitura) — PARCIAL (revisada pelo bate-volta)

> O bate-volta desta mesma leva **reprovou o D-A e o D-S**, que haviam sido dados como entregues.
> O que está abaixo é o estado real depois dos reverts.

| Item | Estado |
| --- | --- |
| **D-A** | ❌ **REVERTIDO.** O índice GiST **nunca anexava**: o Ash emite `tsrange(a0."starts_at"::timestamp, …)` e o índice foi criado sem cast — expressão de índice não casa. Provado por `pg_stat_user_indexes` (contador parado enquanto a app rodava) e pelo plano real sob `movimento_app`: **Seq Scan descartando 10.098 linhas**. Saldo: +1.096 kB e **+43% de latência de INSERT** por ganho zero, e o predicado reescrito ficou **mais lento** que o original. **Volta ao backlog** — ver "D-A, o diagnóstico correto" abaixo |
| **D-S** | ❌ **REMOVIDO.** O seed não tinha guarda de ambiente e `priv/` é embarcado no release (`Dockerfile.prod: COPY priv priv`). Como `clinics`/`users`/`memberships` **não têm RLS**, rodá-lo por engano contra produção deixaria usuário, clínica e membership `owner` reais antes de falhar |
| **D-C** | ✅ Paginação offset+keyset, `required?: false` (nenhum chamador muda). Testes reforçados no bate-volta: empates reais no keyset e guarda de truncamento (101 > `default_limit`) |
| **D-D** | ✅ **já estava feito** (`load_availability_window`, `professional_id` múltiplo, `timezone` no `/auth/me`) — e **coberto por teste** que trava a ordem de grandeza |
| **D-F** | ✅ Índice btree `professional_id` — **auditado e aprovado**: serve o check de FK do `ON DELETE RESTRICT` e virou o índice de leitura dos caminhos recortados por profissional |

Verde ao fim: api **747/0**, gate RLS **7/0**, web **1160/1160**.

### Frente 3 (tempo real & escrita) — COMPLETA

| Item | Estado |
| --- | --- |
| **D-G + D-H** | ✅ O `join` passa a declarar o **modo** (`params["mode"]`). `block` (Dia/Lista) relê o bloco como antes; `signal` (Semana/Mês) **não lê o agendamento** — pergunta o recorte A7 à membership que o `join` já carregou e empurra `agenda_changed`. Medido no caminho real (`Api.QueryCounter` sobre a tabela `appointments`, evento injetado no processo do canal): **modo signal = 0 queries**, modo block > 0. O tópico do **mês ignora `mode: block`**: aquela resolução não tem bloco para empurrar |
| **D-J** | ✅ A cascata (`CascadeToAttendances`) devolve as presenças que ela mesma atualizou (`Enum.map` no lugar de `Enum.each`), e a remarcação reusa as do fetch que checou a versão. Sumiu a **transação nova depois do commit**. Medido: `complete` de **18 → 14 queries**; toques na tabela `attendances` **4 → 3** |
| **D-K** | ✅ `Api.Accounts.ClinicTimezone` — `:persistent_term` com invalidação **local** (síncrona) + **broadcast** para os outros nós (o app roda com `DNSCluster`, e `persistent_term` é por-nó). A invalidação é um **notifier** do recurso, não um `change`: hook de transação e update atômico não coexistem (`MustBeAtomic`), e o notifier vale para qualquer ação de escrita da clínica — inclusive as que ainda não existem. Só o **fuso** entra no cache; `cap_turma_padrao`/`slot_minutos` alimentam validação, e valor de validação não se serve de cache |
| **S1** | ✅ `ApiWeb.SocketRevocation` (notifier de `Membership`) derruba os WebSockets do usuário em `revoke_access` **e** em mudança de papel. O `join` já relia o vínculo; o que faltava era a conexão **já aberta**, cujo escopo é resolvido uma vez e vale enquanto a aba viver. `accept_invite` não derruba (é entrada, não perda de acesso) |
| **D-Q**, **D-N** | ✅ **já estavam feitos** — confirmados no código, sem ação. O D-N virou, de quebra, a função `OwnAgendaOnly.recorte/3`: a mesma regra que filtra linhas passou a responder também sim/não, para o canal não reimplementar a comparação de `professional_id` |

Verde ao fim: api **764/0**, gate RLS **7/0**, web **1159/1159**, `svelte-check` **0 erros**.

**Efeito colateral bom do D-G/D-H:** o evento interno passou a carregar `professional_ids` (origem
**e** destino). Com isso, remarcar trocando de profissional agora avisa **as duas** agendas — antes
o profissional de origem não recebia nada e a contagem dele ficava com um bloco que já não estava lá.

**O que NÃO foi verificado ao vivo (dívida honesta):** o browser não entrou nesta rodada. O MCP do
Playwright está com `evaluate`/`snapshot` quebrados na sessão, e o `playwright test` não sobe porque
`web/build/` é **root-owned** (criado pelo container) — o mesmo atrito de ambiente já registrado. A
prova do canal veio de teste de canal real (`ApiWeb.ChannelCase`, processo de canal de verdade,
evento injetado), não de um clique. **Falta**: abrir a Semana/Mês no browser e ver a contagem mexer.

**Também não feito:** provar por **mutação** que os tetos novos mordem (o teto de queries do D-J e o
`queries == 0` do D-G). É a lição da leva anterior, aplicada só pela metade.

**Achado novo, registrado e não consertado — D-V** ([`30 §4`](30-decisoes-pendentes-agenda.md)): no
modo `block`, remarcar trocando de profissional deixa **bloco fantasma** na tela de quem via a
agenda de origem. A releitura por assinante devolve `nil` (o bloco não é mais dele) e `nil` vira
"não empurra nada" — faltaria um evento de **remoção**, que é decisão de contrato de wire. O modo
`signal` não tem o defeito.

### Frente 4 (fila de espera & holds) — COMPLETA

| Item | Estado |
| --- | --- |
| **F3** | ✅ Cancelar deixou de ser um clique só: abre confirmação com **motivo opcional**, que viaja no form (a coluna `cancel_reason` e a action do BFF já existiam — faltava quem preenchesse). Opcional de propósito: exigir motivo faz a recepção digitar "asdf" para conseguir cancelar |
| **F6** | ✅ Fila paginada (50/página, `?page=`), com **três** consequências que andam juntas: a ordem de prioridade virou ordenação de **banco** (calculation `prio_rank` — paginar sobre ordem aplicada em memória daria "página 2" que não continua a 1); o filtro `?prio=` saiu do cliente para o **servidor**; e as contagens da sidebar passaram a vir do servidor (contar a página contaria errado). `/waitlist/slots` aceita a mesma janela — o motor de vagas só calcula para quem a tela desenha |
| **D-L** | ✅ **Uma transação por lote** (200 clínicas), não por clínica; só os ids são lidos; cron de **5 em 5 min** (era 1). Teste de contagem de `BEGIN` **provado por mutação**: com o código antigo dá "3 transações para 3 clínicas" e falha |
| **F4** | ✅ Indicador "alguém está oferecendo esta vaga" — **sem `Presence`**. A fonte é o próprio `SlotHold` (a linha que a exclusion constraint enxerga): `GET /api/waitlist` devolve as reservas **vivas** com quem segura, o chip da vaga vira cadeado com "Fulana está oferecendo (até 09:10)", e o notifier da fila passou a emitir `slot_held`/`slot_released` para a outra aba recarregar |

Verde ao fim: api **775/0**, gate RLS **7/0**, web **1179/1179**, `svelte-check` **0 erros**.

**A decisão do D-L que vale registrar:** o doc 30 sugeria "statement único com **conexão
privilegiada**". Foi **recusado** — um `DELETE` global só existe para quem bypassa RLS, e abrir no
app um pool (ou uma função `SECURITY DEFINER`) que enxerga todas as clínicas troca um custo
desprezível por um furo permanente no isolamento de tenant. O ADR-018 existe para não ter esse
caminho. O que sobrou (lote + menos frequência) resolve o custo real sem tocar no modelo.

**Por que F4 não virou `Presence`:** Presence responderia "fulano está com o modal aberto" — um
estado que morre com o processo e não sobrevive a um refresh. O hold responde "esta vaga está
reservada até tal hora", que é o que a recepção precisa saber, já existe no banco, vale entre nós
e é o **mesmo dado** que o 409 usa. O chip é aviso, não portão: continua clicável, e quem clicar
leva o 409 com quem segura e até quando.

**Dívida honesta desta frente:** de novo, **nada foi clicado no browser** (mesmo atrito: MCP do
Playwright quebrado, `web/build` root-owned). E a prova por **mutação** foi feita só no D-L — os
tetos e chips novos de F3/F4/F6 têm teste, mas não a prova de que mordem.

### D-A — o diagnóstico correto (para quando voltar)

O problema medido é real: o plano varre o histórico porque só `starts_at` é indexável e o limite
inferior (`ends_at`) vira filtro. O que estava errado era a **solução e a medição**:

- **A medição foi feita com SQL escrito à mão**, sem os casts que o AshPostgres injeta. Qualquer
  benchmark futuro tem de sair do caminho da aplicação (`list_appointments!`), não do `psql`.
- **Um índice de expressão só anexa se a expressão bater byte a byte** com a da query. Com
  `:utc_datetime` (que é `timestamp(0)`), o Ash emite `::timestamp` — o índice precisa do mesmo
  cast, ou o fragment precisa ser escrito sem `?` nas colunas.
- **O ganho só existe na janela de Dia** (~1% de seletividade). Em mês e relatórios o seq scan é
  a escolha correta do planner e continuará sendo.
- **O keyset do D-C também não indexa**: o Ash emite `((a = $1) AND (b > $2)) OR (a > $3)`, que o
  Postgres não converte em bound de índice — `Ash.stream!` custa ~2,6× o read completo. A
  paginação segue correta e útil como bound de memória, mas não como ganho de banco.
- **Nenhum teste fixa plano de query.** Um teste que rode `EXPLAIN` e afirme o índice no plano
  teria pego isto no commit — é o que falta antes de tentar de novo.

### Achado ao iniciar a Onda 1 (D-M já existia, mas o gate estava quebrado)

A infra do D-M **já estava semeada**: existe [`test/api/rls_smoke_test.exs`](../api/test/api/rls_smoke_test.exs)
com `@moduletag :rls` e o job `api-rls` em [`ci.yml`](../.github/workflows/ci.yml). Porém o passo
que cria o role restrito conecta em `psql -d api_test`, enquanto o banco de teste é
`movimento_test` ([`config/test.exs`](../api/config/test.exs)). Com `ON_ERROR_STOP=1` o passo
falha antes de `mix test --only rls`; como o CI só dispara em push→`main`/PR e o trabalho corre na
`develop`, **o gate nunca rodou verde**. Correção do D-M nesta onda = tornar o gate real (nome do
banco correto) + provar verde, e não remontá-lo do zero.

---

## Ambiente

**O caminho normal é o container, e ele funciona** — inclusive numa distro WSL sem a integração
Docker ativada, usando o binário do Windows (`/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe`):

```bash
docker compose up -d                       # db + api + web
docker compose exec api mix test
docker compose exec api mix ash.codegen add_alguma_coisa
docker compose exec web npm run check
```

> ⚠️ **Correção registrada.** Durante a execução desta leva eu concluí — e cheguei a escrever
> aqui — que "a stack não roda em container neste ambiente". **Era falso.** A conclusão veio de um
> `docker run -v <path-wsl>` avulso que monta vazio; os bind mounts dos **serviços do compose**
> resolvem normalmente. O container escreve na source montada, inclusive em
> `priv/resource_snapshots` — que é justamente o que bloqueia o `mix ash.codegen` pelo host.
> Prefira o container; ele não tem esse problema.

### Alternativa: rodar no host

Serve quando não se quer subir a stack inteira. Elixir 1.18.4/OTP 27 via asdf + um Postgres em
container:

```bash
docker run -d --rm --name pg -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres -p 5432:5432 postgres:16

cd api && DATABASE_HOST=localhost mix deps.get
DATABASE_HOST=localhost MIX_ENV=test mix ash.setup     # cria movimento_test
DATABASE_HOST=localhost MIX_ENV=test mix test          # suíte (como postgres, BYPASSRLS)
```

**Gate de RLS** (como `movimento_app`, NOBYPASSRLS — é o que prova GUC/tenancy):

```bash
docker exec -i pg psql -U postgres -d movimento_test -v ON_ERROR_STOP=1 < priv/sql/setup_app_role.sql
DATABASE_HOST=localhost DATABASE_USER=movimento_app DATABASE_PASSWORD=movimento_app \
  SKIP_DB_SETUP=1 MIX_ENV=test mix test --only rls
```

`SKIP_DB_SETUP=1` é obrigatório no gate: o role restrito não tem CREATE no schema (é o desenho).

`DATABASE_PORT` (parametrizado nesta leva, default 5432) é o que permite alcançar o Postgres do
compose na :5434 a partir do host.

> **Dado de volume.** O `movimento_dev` **tem ~10,2k agendamentos** numa clínica dedicada
> ("Volume (perf)"), úteis para medir. O script que os gerou **foi removido** do repositório (ver
> D-S acima): `priv/` embarca no release e ele não tinha guarda de ambiente. Se o volume precisar
> ser recriado, o gerador deve nascer **fora de `priv/`** — em `test/support/` (que não vai para a
> imagem) ou como `Ash.Generator`, que é o que as rules do projeto pedem e o repo ainda não usa.

Dois avisos, se a suíte falhar de forma estranha **no host**: diretórios gerados pelo container
(`.svelte-kit/`, `api/priv/resource_snapshots/`) podem estar **root-owned**, o que quebra
`svelte-check`/`vitest` e o `mix ash.codegen` com EACCES — no container isso não acontece; e o
`node_modules` do host pode estar desatualizado (rode `npm ci`).
