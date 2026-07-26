# 35 — Plano de execução do backlog (Ondas)

Consolidação **acionável** do que foi adiado/deferido e priorizado para execução. As fontes de
verdade dos itens continuam sendo [`08-roadmap.md`](08-roadmap.md),
[`30-decisoes-pendentes-agenda.md`](30-decisoes-pendentes-agenda.md),
[`33-relatorios.md`](33-relatorios.md) e os bate-voltas; este doc só **agrupa e sequencia** a
seleção aprovada, em frentes coesas por trilha de código + dependência.

Natureza do bloqueio: **[P]** decisão de produto · **[T]** técnico/arquitetura · **[P+T]** ambos.

> ## ▶︎ Onde retomar
>
> **A Onda 4 fechou (2026-07-26)** — Frente 10 inteira: perf/estrutura (#52–#55) e os gatilhos que
> sobravam (#48, #50, #51, #56). Registro em [`44`](44-onda-4-notificacoes.md); os três gates de
> produto que a bloqueavam foram decididos na abertura dela. Auditada em
> [`45`](45-bate-volta-onda-4.md): cinco causas corrigidas, **zero achados de segurança**, e o
> `oban_jobs` ganhou a poda que faltava — o projeto tinha duas podas e nenhuma para a fila que
> executa as duas.
>
> **A Onda 3 fechou (2026-07-25).** Frentes 5 (Pacotes/A1), 6 (Turma/A2, as cinco etapas) e 7
> (Histórico da ficha) feitas — o **caminho crítico** `D-C → A1 → A2 → C13/#47` está inteiro. As
> Ondas 1 e 2 já haviam fechado, sobrando só o **D-S** (seed removido) e o **D-A**, que foi
> resolvido pelo teto de 8h (ver "D-A: fechado pelo teto").
>
> **A Onda 5 fechou (2026-07-26)** — Frente 11 inteira, registro em
> [`46`](46-onda-5-producao.md). O levantamento mudou a onda: a maior parte do **H59** já estava
> feita (CSP, X-Frame, nosniff, Referrer-Policy, sign-out POST, cookie `secure` pelo default do
> SvelteKit — que falha fechado), e o que faltava era o **HSTS**, que o doc 17 e o `prod.exs`
> davam como resolvido pela edge do Fly. Não era: `force_https` é redirect, não header. **S3**
> (CSP por ambiente, via `API_PUBLIC_ORIGIN` no build), **S2** (token do WS no subprotocolo — o
> Phoenix 1.8 já suportava de fábrica) e **H64** (4 FKs corrigidas + teste de contrato que exige
> decisão explícita para FK nova) fechados.
>
> O levantamento achou ainda **dois erros que bloqueavam o primeiro deploy**: o
> `GOOGLE_REDIRECT_URI` do doc 17 apontava para a API quando o callback do Google é rota do
> **web**, e o `prod.exs` descrevia um proxy Caddy que não existe mais. Os dois corrigidos.
>
> Próximo passo: **Onda 6 — Frentes 8, 9, 12 e 13** (features soltas, auditoria e refactors).
> Fica **um item aberto de decisão humana** antes dela, registrado no [`46` §6c](46-onda-5-producao.md):
> `appointments.package_id` é coluna morta (0 de 10.212 linhas) desde que a A2 moveu o pacote para
> a presença — e leva junto uma tarja de UI que nunca aparece e um índice mantido a cada escrita.
>
> A lição que a Onda 4 acrescentou: **a paginação era pré-requisito do índice, não o contrário.**
> Entregar o #55 antes do #54 teria produzido um índice íntegro e nunca escolhido — o mesmo
> desfecho do D-A. E o índice parcial só anexou quando o predicado passou a repetir o cast
> (`::timestamp`) que o AshPostgres emite, o que é a lição do D-A cobrada uma segunda vez.
>
> Lições que a Onda 3 reforçou:
>
> - **clicar no browser continua achando o que a suíte não acha.** O drawer da presença passou em
>   20 testes de componente e falhava no primeiro clique real: o form submetia antes do flush do
>   Svelte e ia vazio. O `fireEvent` do testing-library devolve depois do flush — por isso o teste
>   passava. A regressão agora afirma **no momento do submit**;
> - **mutação continua sendo o que separa teste de decoração**: 11 mutações rodadas nesta onda,
>   todas com teste vermelho (dono do pacote, `sozinho?`, corte de data, normalização de erro,
>   ordem das cláusulas do notifier, `tick` do drawer, corte do fan-out);
> - **o gate `:rls` tem um limite medido**, agora escrito no próprio arquivo: o sandbox roda o
>   teste numa transação só, então o **primeiro** `in_clinic` do caminho deixa a GUC pendurada —
>   tirar o `in_clinic` de uma leitura **interna** continua passando. O gate prova a porta de
>   entrada e a escrita; leitura interna sem GUC segue sendo achado de revisão.

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

1. ~~**A2 (Turma):** presença individual é requisito? + bug do `pkgOf`.~~ ✅ **RESOLVIDO**
   (2026-07-24, doc 41): é requisito, e **sem migração** — o enum do bloco ficou, o que mudou foi
   quem escreve o status (rollup das presenças).
2. **A3 (futureConflicts):** estender D12 (horário do profissional) para clínica/exceção + o
   terceiro consumidor esquecido (`addHoliday`). — bloqueia Frente 8.
3. ~~**F#48:** limiar de "paciente urgente entrou na fila".~~ ✅ **RESOLVIDO** (2026-07-26): **só
   `urgente`**. `alta` é frequente demais em clínica movimentada, e sino que apita demais deixa de
   ser olhado (doc 31 §4).
4. **D-Aud1:** semântica do rótulo "X–Y de Z" (reltuples / `countable:false`+limit+1 / contar
   só com filtro). — bloqueia Frente 12. **A Onda 4 acrescentou dado a este gate**: `countable`
   vira `COUNT(*) OVER ()` e lê o recorte inteiro apesar do `LIMIT` — medido em 10.265 buffers
   contra 26 ([doc 44](44-onda-4-notificacoes.md) §2). O `Api.Pagination.page_opts/1` já aceita
   `count: false`.

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

### Frente 2 — Performance de leitura da agenda ✅ FEITA
- **D-C** — paginar o `:in_range`. **Antes da Fatia 3** (Pacotes reusa o read com janelas maiores).
- **D-A** ✅ **fechado pelo A2** (doc 36 §6.2), não pelo índice — ver "D-A: fechado pelo teto, não
  pelo índice" abaixo. O GiST continua **descartado**.
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

### Frente 5 — Pacotes (Fatia 3) ✅ FEITA
- **A1** — `computeSerie` (domínio puro + Oban), débito com falta punitiva, pausar/retomar
  reprojetando p/ futuro (GAP-06). Commits até `cb86851`; bate-volta em [`42`](42-bate-volta-pacotes-e-turma.md).

### Frente 6 — Turma (Fatia 5) ✅ FEITA — as cinco etapas
- **A2** — presença e débito por participante ([`41`](41-turma-presenca-por-participante.md)).
  O `pkgOf` do protótipo foi resolvido pela raiz: a massa opera sobre **presenças**, então
  cancelar o pacote da Maria não cancela mais a turma do João. Detalhe por etapa no doc 41.

### Frente 7 — Ficha do paciente (C13, parcial) ✅ FEITA
- **C13** — **Pacotes** (`af9d651`) e **Histórico** (`5f7c592`) destravados. O histórico é por
  PRESENÇA, com teto de leitura e aviso de corte. **Anexos** seguem ocultos (v2); `faltas` na
  ficha do drawer continua dependendo de F1.

### Frente 8 — futureConflicts (Fatia 7, A3) *(gate #2)*
- **A3** — ligar o motor `ImpactAnalysis`/`futureConflicts` ao editar horários. **[P]**

### Frente 9 — Realtime "quem está vendo este dia" (F5)
- **F5** — `Phoenix.Presence` por dia (feature nova, isolada).

### Frente 10 — Notificações ✅ FEITA (2026-07-26, [doc 44](44-onda-4-notificacoes.md))
- **Perf/estrutura:** #52 `who_fits` síncrono → Oban; #53 `mark_all_read` via `Ash.bulk_update`;
  #54 LIMIT/paginação + poda/expurgo; #55 índice `[clinic_id, recipient_id, inserted_at]` — **sem
  o `desc`** (btree lê ao contrário) e com um segundo, parcial, para as não-lidas. O **P5** caiu
  junto com o #52, como a auditoria previu.
- **Gatilhos:** ~~#46 `:faltou`~~ e ~~#47 `participant_added`~~ **FEITOS na A2 etapa 5**
  (`60808a6`) — o #46 na forma da A2: a falta é da **presença**, então o notifier passou a
  escutar a `Attendance`. ~~#48~~ (só `urgente`), ~~#50~~ (papel ao afetado; remoção à governança,
  porque o removido perde acesso à caixa daquela clínica), ~~#51~~ (os dois lembretes) e ~~#56~~
  (`/agenda?date=`, `/fila?prio=urgente`) **feitos na Onda 4**.

### Frente 11 — Endurecimento de produção ✅ FEITA (2026-07-26, [doc 46](46-onda-5-producao.md))
- ~~**H59**~~ — cookie `secure`, CSP/X-Frame e sign-out POST **já estavam feitos** (doc 13); o que
  faltava era o **HSTS**, que ninguém emitia porque o doc 17 o dava como sendo da edge do Fly.
- ~~**S3**~~ — `connect-src` derivado de `API_PUBLIC_ORIGIN` no build (`kit.csp` é build-time,
  então entra por `[build.args]`, não pelo `[env]` do fly.toml).
- ~~**S2**~~ — token no subprotocolo `Sec-WebSocket-Protocol` (`auth_token: true`), com a porta da
  query string **fechada** (403). O interruptor é opção do **socket**: dentro de `websocket:` o
  Phoenix o anula em silêncio, e a suíte não vê.
- ~~**H64**~~ — `created_by_id` e os dois `*_versions.user_id` saíram de `NO ACTION` para
  `SET NULL` (senão nenhum `User` seria apagável, que é o que a F8 precisa); `attendances.package_id`
  ganhou a FK que nunca teve.

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
| **3 — Valor central** | 5 → 6 → 7 | ✅ **feita (2026-07-25)** | Pacotes → Turma → Ficha, sequencial por dependência |
| **4 — Notificações** | 10 | ✅ **feita (2026-07-26)** | Perf antes dos gatilhos — e a paginação acabou sendo pré-requisito do índice |
| **5 — Produção** | 11 | ✅ **feita (2026-07-26)** | Antes do primeiro deploy real — e achou dois erros que o bloqueavam |
| **6 — Soltas + limpeza** | 8, 9, 12, 13 | pendente ← **próxima** | Features isoladas, auditoria e refactors por último |

**Caminho crítico:** D-C → A1 (Pacotes) → A2 (Turma) → C13/#47. ✅ **percorrido inteiro.**

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

### Frente 2 (performance de leitura) — COMPLETA (2026-07-24)

> O bate-volta desta mesma leva **reprovou o D-A e o D-S**, que haviam sido dados como entregues.
> O D-A voltou depois, por outro caminho (A2); o D-S segue removido.

| Item | Estado |
| --- | --- |
| **D-A** | ✅ **fechado em 2026-07-24 — sem índice novo.** O conserto foi o par do A2: `CHECK (ends_at <= starts_at + interval '480 minutes')` no banco **e** o corte `starts_at > from − 8h` no `:in_range` (`Preparations.WindowLowerBound`). Medido no SQL que a app emite, sobre as 10.204 linhas do `movimento_dev`: **Seq Scan / 10.099 linhas descartadas / 231 buffers / 1,41 ms** → **Index Scan em `appointments_clinic_id_starts_at_index` / 103 buffers / 0,11 ms**, com a **mesma resposta** (105 = 105 linhas). Detalhe abaixo |
| ~~**D-A**~~ | ❌ (histórico) O índice GiST **nunca anexava**: o Ash emite `tsrange(a0."starts_at"::timestamp, …)` e o índice foi criado sem cast — expressão de índice não casa. Provado por `pg_stat_user_indexes` (contador parado enquanto a app rodava) e pelo plano real sob `movimento_app`: **Seq Scan descartando 10.098 linhas**. Saldo: +1.096 kB e **+43% de latência de INSERT** por ganho zero, e o predicado reescrito ficou **mais lento** que o original. **Volta ao backlog** — ver "D-A, o diagnóstico correto" abaixo |
| **D-S** | ❌ **REMOVIDO.** O seed não tinha guarda de ambiente e `priv/` é embarcado no release (`Dockerfile.prod: COPY priv priv`). Como `clinics`/`users`/`memberships` **não têm RLS**, rodá-lo por engano contra produção deixaria usuário, clínica e membership `owner` reais antes de falhar |
| **D-C** | ✅ Paginação offset+keyset, `required?: false` (nenhum chamador muda). Testes reforçados no bate-volta: empates reais no keyset e guarda de truncamento (101 > `default_limit`) |
| **D-D** | ✅ **já estava feito** (`load_availability_window`, `professional_id` múltiplo, `timezone` no `/auth/me`) — e **coberto por teste** que trava a ordem de grandeza |
| **D-F** | ✅ Índice btree `professional_id` — **auditado e aprovado**: serve o check de FK do `ON DELETE RESTRICT` e virou o índice de leitura dos caminhos recortados por profissional |

Verde ao fim: api **780/0** (4 doctests), gate RLS **7/0**, cobertura **91,5%**.

#### D-A: fechado pelo teto, não pelo índice

O diagnóstico do bate-volta continua valendo — o problema é que só `starts_at` é indexável e o
limite inferior (`ends_at`) vira residual, então `starts_at < to` varre o histórico inteiro. O que
mudou foi a **solução**: em vez de ensinar o banco a indexar o intervalo (GiST), ensinou-se a query
a não pedir o passado.

Isso só é correto porque nenhum bloco dura mais que 8h — e **é aí que mora o trabalho de verdade**.
O teto já existia como `max: 480`, mas em três cópias e só na aplicação; `Ash.Seed`, script de
manutenção ou `INSERT` à mão passavam direto, e uma linha de 10h escrita por fora **sumiria da
agenda** sem erro nenhum. Então:

- a constante virou fonte única em [`Api.Scheduling.Duration`](../api/lib/api/scheduling/duration.ex),
  consumida pelas duas `constraints:`, pelo CHECK e pelo corte da query;
- o CHECK `appointments_duration_within_cap` desceu para o banco (tabela limpa: 0 linhas violando,
  máximo real 50 min) — mesma jogada do CHECK de duração positiva do commit `3a2f27c`;
- o corte é **preparation, não `filter expr()`**: a subtração acontece em Elixir para o bound chegar
  ao SQL como **literal**. É a lição do D-A aplicada — índice só vira bound com constante em tempo
  de plano.

**Por que o `::timestamp` não atrapalhou desta vez** (a causa da morte do D-A): o cast aparece no
`Index Cond` e o índice é usado assim mesmo, porque a coluna **já é** `timestamp(0)` e o cast é
no-op sobre coluna nua. O que não funciona é índice de **expressão**, que precisa casar byte a byte.

**Prova de que o teste morde** (as duas, feitas): derrubar o CHECK no banco de teste faz o teste do
teto falhar; trocar o corte para `−4h` faz o teste do bloco de 8h falhar. Há ainda um terceiro
teste que lê `pg_get_constraintdef` e compara com a constante do Elixir — é o que impede editar
`Duration` sem gerar migration, que não quebraria nada mais.

**O que continua sem rede:** nenhum teste fixa **plano**. Um `EXPLAIN` na suíte seria teatro — com
tabela de dezenas de linhas o planner escolhe Seq Scan e está certo. A medição de plano vive fora
da suíte, no `movimento_dev`, e o roteiro está acima.

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
| **D-L** | ✅ e depois **SEM OBJETO**: o worker foi otimizado (lote de 200 + 5 min, teste de `BEGIN` provado por mutação) e removido dias depois junto com a tabela que ele varria ([`39`](39-fila-sem-reserva-de-vaga.md)). A lição fica: a otimização estava certa, o **item** é que era — ninguém tinha perguntado se a tabela precisava existir |
| **F4** | ✅ **entregue, e depois REFEITO** ([`39`](39-fila-sem-reserva-de-vaga.md)). A primeira versão saiu sobre o `SlotHold`; a verificação ao vivo mostrou que a UI **nunca** criava reserva (`git log -S'?/oferecer'` → vazio), e a reserva inteira foi removida. Hoje o aviso é `Phoenix.Presence`: aparece enquanto o modal está aberto, some quando a aba morre, e **não trava nada** — o portão sempre foi a exclusion constraint do agendamento |

Verde ao fim: api **775/0**, gate RLS **7/0**, web **1179/1179**, `svelte-check` **0 erros**.

**A decisão do D-L que vale registrar:** o doc 30 sugeria "statement único com **conexão
privilegiada**". Foi **recusado** — um `DELETE` global só existe para quem bypassa RLS, e abrir no
app um pool (ou uma função `SECURITY DEFINER`) que enxerga todas as clínicas troca um custo
desprezível por um furo permanente no isolamento de tenant. O ADR-018 existe para não ter esse
caminho. O que sobrou (lote + menos frequência) resolve o custo real sem tocar no modelo.

**Por que F4 acabou virando `Presence` (revisão de 2026-07-24):** o argumento original era que o
hold "sobrevive a um refresh e é o mesmo dado do 409". Ele caiu quando a sonda ao vivo mostrou que
**a UI nunca criava hold nenhum** — o dado não existia para sobreviver a coisa alguma. Ver
[`39`](39-fila-sem-reserva-de-vaga.md): o que morre com o processo é justamente a propriedade
desejada, porque a vaga deixa de ficar presa.

**Dívida honesta desta frente:** de novo, **nada foi clicado no browser** (mesmo atrito: MCP do
Playwright quebrado, `web/build` root-owned). E a prova por **mutação** foi feita só no D-L — os
tetos e chips novos de F3/F4/F6 têm teste, mas não a prova de que mordem.

> **Fechada pelo bate-volta** ([`38`](38-bate-volta-frentes-3-e-4.md)): o browser entrou (render +
> `curl` com sessão real, porque o `click` do MCP está quebrado) e provou D-G/D-H, F4 e F6 ao vivo.
> A rodada adversarial achou **um bug de correção do F6** — a lista e o motor de vagas pediam
> janelas diferentes quando havia filtro — corrigido e provado por mutação. Restam F3 e S1 sem
> verificação de browser, por dependerem de clique.

### Onda 3 (valor central) — COMPLETA (2026-07-25)

| Frente | Estado |
| --- | --- |
| **5 — Pacotes (A1)** | ✅ série + débito + pausar/retomar/cancelar, com o bate-volta [`42`](42-bate-volta-pacotes-e-turma.md) fechado |
| **6 — Turma (A2)** | ✅ **as cinco etapas** — presença por participante, `package_id` na entrada, massa sobre presenças, tela e notificações. Ver [`41`](41-turma-presenca-por-participante.md) |
| **7 — Ficha (C13)** | ✅ Pacotes + Histórico destravados (Anexos ficam para v2) |

**O que a A2 mudou de modelo, em uma frase:** o desfecho do bloco deixou de ser um clique e virou
**rollup das presenças** — e, como consequência, toda a massa de pacote passou a operar sobre
presenças, que é o que fecha o bug do `pkgOf` do protótipo (cancelar o pacote de um paciente
cancelava a turma dos outros).

Achados desta leva que valem além dela:

- **o form que submetia vazio** (etapa 4): atribuir campos e chamar `requestSubmit()` no mesmo
  tick não funciona no Svelte 5 — os `value` ainda não foram escritos. O teste de componente
  passava porque o `fireEvent` do testing-library devolve **depois** do flush. Só o clique real
  denunciou; a regressão agora espiona `requestSubmit` e afirma no momento do submit;
- **quem aborta a transação da massa é o Ash**, não o `Repo.rollback/1` do laço: a ação que falha
  chama `rollback(changeset)` na transação que não abriu, e o que sai é um `Ash.Changeset` cru —
  sem normalizar, a fronteira devolvia **400** para o que é 422 de conflito;
- **sucesso silencioso é pior que erro**: `bulk_*` sobre um pacote inexistente respondia
  `{:ok, %{afetadas: 0}}`. Virou 404, com `uuid?/1` antes do read (id malformado estoura no Ash —
  o mesmo 500 do doc 32);
- **a ordem das cláusulas de um `Ash.Notifier` é contrato**: a específica (`:add_participant`)
  tem de vir antes da geral, que casa qualquer nome. Invertidas, o sintoma é *uma notificação a
  menos*, sem erro nenhum — por isso virou comentário no módulo **e** teste de mutação;
- **o limite do gate `:rls`**, medido e escrito no arquivo: o sandbox roda o teste numa transação
  só, então o primeiro `in_clinic` do caminho deixa a GUC pendurada. Tirar o `in_clinic` de uma
  leitura **interna** continua passando o gate. Ele prova a porta de entrada e a escrita.

Verde ao fim: api **928/0** (91,7% de cobertura), gate RLS **7/0** como `movimento_app`, web
**1268/1268** (91,3% stmts), `svelte-check` 0 erros. Verificação ao vivo no browser: falta por
participante → rollup + contador de faltas, justificar → contador volta, massa move as 4 sessões
do pacote e o histórico da ficha reflete.

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
