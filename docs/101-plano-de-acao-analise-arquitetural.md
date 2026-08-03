# 101 — Plano de ação da análise arquitetural

**Data:** 2026-08-03 · **Base:** análise arquitetural completa do repositório (`develop`)
· **Acumuladores:** [`00-decisoes.md`](00-decisoes.md), [`50-debitos-tecnicos.md`](50-debitos-tecnicos.md)

Este documento registra a análise arquitetural de 2026-08-03 e o plano de execução que ela gerou.
Diferente dos docs de bate-volta, que auditam **uma fatia recém-escrita**, esta análise olhou o
repositório inteiro: 10 domínios Ash, 28.590 LOC de backend, 12.530 LOC de TS de produção, 99 rotas
HTTP, 71 migrations.

Toda correção segue a regra do [CLAUDE.md](../CLAUDE.md): **teste vermelho antes do conserto**.

---

## 1. O retrato

| Área | Medida |
| --- | --- |
| `api/lib` | 243 arquivos `.ex`, **28.590 LOC** |
| `api/test` | 130 arquivos, **29.722 LOC**, **1.645 testes** |
| Migrations | 71 · Domínios Ash 10 · Recursos Ash 22 |
| Controllers | 23 · Rotas HTTP 99 · Oban workers 10 |
| `web/src` | 96 `.svelte` (16.878 LOC) + 12.530 LOC TS de produção |
| Testes web | 186 arquivos (24.884 LOC) + 25 specs Playwright |
| Docs | 100 arquivos numerados |
| Gates | api ≥80% (`api/coveralls.json`) · web 80/80/80/75 (`web/vite.config.ts`) |

Relação teste:produção ≈ **1:1** no backend e ≈ **2:1** no web.

### 1.1 O que está bem, e por quê

Não é elogio de cortesia — é o que **não** precisa mexer, e por isso entra num plano de ação.

- **A fronteira de tenancy é uma só, defendida em três camadas independentes.** Multitenancy do
  Ash por `clinic_id`; `Api.Scope` como única fonte de tenant (nunca vem do corpo); RLS no Postgres
  sob role `cinetra_app` NOBYPASSRLS. E o CI tem um **job dedicado** rodando como `cinetra_app`
  contra `api/test/api/rls_smoke_test.exs`. A asserção "não-vazio" parece fraca e é exatamente
  certa: o modo de falha da RLS é zero linhas em silêncio.
- **O relógio é injetado.** `Api.Scope` carrega `now` resolvido e o propaga pelo contexto; nenhuma
  regra temporal lê `DateTime.utc_now/0` no domínio. É a decisão que mais paga juros num sistema de
  agenda.
- **O recorte A7 não é reimplementado no WebSocket.** `agenda_channel.ex:135` relê o bloco com o
  escopo do assinante e delega a `OwnAgendaOnly`; no modo `signal` suprime até o *aviso*, senão o
  profissional deduziria pelo "recarregue o dia" que há algo na agenda do colega.
- **Concorrência resolvida no banco.** Exclusion constraint com `btree_gist`, `FOR UPDATE` antes do
  rollup, locking otimista por `version`. A validação Ash dá a mensagem; a constraint é a verdade.
- **Guarda de boot CSP↔runtime que derruba o container** (`web/src/hooks.server.ts:20`). Converte
  uma classe inteira de "funciona em dev, quebra em prod" em falha de partida.
- **Webhooks fail-closed por construção**, com o compose abortando o `up` sem os secrets.
- **Motores puros + code interface no domínio.** `Availability`, `ImpactAnalysis`, `SlotFinder`,
  `Series` recebem tudo carregado e não tocam banco; as actions só orquestram.
- **Proveniência.** Quase toda decisão não-óbvia carrega o número medido e o doc de origem. É o que
  permitiu esta análise ser específica em vez de genérica.

---

## 2. Os achados

Numeração: **A** = alto, **M** = médio, **B** = baixo. O que já estava em
[`50-debitos-tecnicos.md`](50-debitos-tecnicos.md) aparece marcado como `[D-nn]` e **não** é
novidade — está aqui só para dizer o que segue aberto.

### 2.1 Alto

| # | Achado | Evidência | Impacto |
| --- | --- | --- | --- |
| **A1** | **Bus factor = 1.** 268 commits, um autor. A arquitetura depende de invariantes não-óbvias (a GUC pendurada, o A7 em três lugares, a ordem da árvore de supervisão) que vivem em prosa e nunca foram exercitadas por um segundo leitor. | `git log --format=%an \| sort \| uniq -c` | As duplicações estruturais abaixo são, na prática, apostas de que quem editar uma cópia vai lembrar das outras. |
| **A2** | **Contrato BFF↔API duplicado à mão.** ~68 `interface` TS espelhando serializers Elixir, sem codegen nem fixture compartilhada. Os testes do BFF mockam `fetch` com JSON escrito no próprio teste — validam o BFF contra o BFF. | `web/src/lib/server/` (25 arquivos, 2.666 LOC); o modo de falha já ocorreu, narrado em `web/src/lib/agenda.ts:17-21` | Campo renomeado num `*_json.ex` não quebra build nem teste: aparece em runtime como `undefined` silencioso. |
| **A3** | **Assimetria de autorização no ciclo de vida do pacote.** `list_package_attendances/3` lê com `scope:` (→ `OwnAgendaOnly` recorta por `appointment.professional_id`); a irmã `list_sessions_including_held/3` lê com `authorize?: false` (sem recorte). Como `future_sessions/3` e `held_targets/2` derivam o conjunto de blocos a partir das **presenças**, o conjunto efetivo herda o recorte A7. | `api/lib/api/scheduling.ex:1157` vs `:1176`; `api/lib/api/packages.ex:289`, `:228` | Para pacote com sessões em colunas de profissionais diferentes e ator `profissional`: `cancel_package` marca o pacote `:cancelado` mas **cancela só as sessões da coluna do ator**; `archive_package` pode ver `futuras == []` e arquivar pacote com sessões vivas. **Não é vazamento — é corrupção silenciosa de estado**, pior de diagnosticar. |
| **A4** | **`[D-13]` documentos legais no ar com placeholders**, sem revisão jurídica, já indexados no sitemap. Adjacente: **`[D-14]`** o aceite não é registrado em lugar nenhum. | `50-debitos-tecnicos.md` | Bloqueia publicação (art. 9º da LGPD). Dos 18 débitos catalogados, **17 abertos, 1 parcial**. |
| **A5** | **Regras de negócio espelhadas nos dois lados, sem contrato de teste.** CPF, CNPJ, telefone, e-mail e períodos têm par Elixir/TS. Cada `.ts` traz o comentário "espelho de X" — e **a prosa é a única verificação**. | `api/lib/api/cpf.ex` ↔ `web/src/lib/cpf.ts`, e mais 4 pares | `docs/04 §10` prescreveu "paridade garantida por contrato de teste compartilhado, nunca por cópia mantida a olho". Esse contrato nunca foi construído. |

### 2.2 Médio

| # | Achado | Evidência |
| --- | --- | --- |
| **M1** | `future_conflicts` varre a agenda futura inteira, **sem teto, dentro da transação de escrita** do expediente. `ImpactAnalysis.conflicts/4` ainda roda `day_periods/3` duas vezes por agendamento afetado. | `api/lib/api/scheduling.ex` (`escrever_semana_da_clinica/2`, `escrever_grade/3`), `schedule_exception/changes/check_future_conflicts.ex:23` |
| **M3** | **Bug provado.** A paginação do histórico da ficha lê `limit + 1`, **depois** rejeita presenças com `.appointment` nulo (`pkg_hold`), e só então calcula `more?` sobre a lista já reduzida. Sumindo ≥1, `more?` vira `false` **com mais linhas no banco**. | `api/lib/api/scheduling.ex:549-551` |
| **M4** | **Nenhum timeout em `apiFetch`.** A única chamada com `AbortSignal.timeout` no repositório é o readiness. | `web/src/lib/server/api.ts:50-54` |
| **M5** | Fan-out de notificações e mensagens é O(n) síncrono no pós-commit, com uma transação por participante em `Dispatch`. Numa turma de 8, ~32 idas ao banco. Some `ja_confirmada?/1`, um N+1 clássico. | `api/lib/api/notifications/fanout.ex:432`, `api/lib/api/messaging/notifier.ex:212`, `:254` |
| **M6** | O canal relê o bloco do banco **uma vez por assinante, por evento**, e o `bloco_load()` traz subconsulta correlacionada + agregado com sort. Escala com assinantes × eventos, não com o dado. | `api/lib/api_web/channels/agenda_channel.ex:135`, `api/lib/api/scheduling.ex:97-108` |
| **M7** | Rate limit é Hammer/ETS (estado por-nó) e o do endpoint público do BFF é um `Map` em memória de processo; o compose não define réplicas. `db`, `api` e `web` são instâncias únicas na mesma máquina. | `api/lib/api/application.ex:44-45`, `web/src/routes/api/client-error/+server.ts:30`, `deploy/compose.dokploy.yml` |
| **M8** | `Poda.por_clinica/1` é um `Enum.reduce` sem `rescue`: um erro numa clínica (ex.: o `{:ok, n} =` de `em_lote/4`) mata a poda de **todas** naquela rodada. Os vizinhos `reminder_job.ex` e `prune_attachments.ex` já têm `rescue` por unidade. | `api/lib/api/housekeeping/poda.ex:65-67`, `:117` |
| **M9** | `Api.Waitlist.AvailabilityRule` **não gera trilha de auditoria** — as regras entram por `manage_relationship` e o diff do pai ignora relacionamentos. Trocar a disponibilidade de um item da fila não deixa rastro. Correlatos menores: `Accounts.User` sem `Capture`; `PruneAttachments` destrói sem `anexo_tocado/3`. | `api/lib/api/waitlist/availability_rule.ex` |
| **M10** | `[D-11]` `messages` sem retenção — e o que cresce contém PII de titular (`vars` com nome do paciente, `destino` com telefone/e-mail congelado), num sistema que definiu retenção explícita para as três tabelas vizinhas. | `api/lib/api/messaging/dispatch.ex:339`, `message.ex:320` |
| **M11** | `exigirJson` (guarda CSRF) aplicada em 2 dos 4 `+server.ts` que mudam estado — falta nos dois de pacotes, que leem o corpo com `request.json()` (que ignora o content-type). O próprio `csrf.ts` documenta que a checagem nativa do Kit não cobre POST sem content-type. | `web/src/lib/server/csrf.ts:9-26`; falta em `routes/(app)/pacientes/[id]/pacotes/+server.ts` e `.../preview/+server.ts` |
| **M12** | **Reply-To é código morto.** `patient_emails.ex` lê `message.vars["clinica_email"]`, e `Dispatch.vars/3` nunca preenche a chave — `grep` retorna **uma** ocorrência no repositório inteiro. O `moduledoc` promete que "a resposta do paciente cai na clínica"; ela cai em `nao-responda@`. | `api/lib/api/messaging/patient_emails.ex:66-68` |

> **M2 do rascunho caiu na verificação.** A suspeita era leitura por-tenant fora da GUC em
> `Api.Packages.Sessions.segura/3`. O código **usa** `Api.Tenancy.in_clinic/2`
> (`api/lib/api/packages/sessions.ex:82-89`), com comentário registrando exatamente o risco
> (`22P02` porque a GUC volta a `''` e não a NULL, doc 96 T-0/T-1). Fica registrado porque a
> hipótese era razoável e a refutação é informação.

### 2.3 Baixo

| # | Achado | Evidência |
| --- | --- | --- |
| **B1** | ADR-002 diverge da implementação: `AshJsonApi` está montado e **vazio** (`Api.Meta` tem `routes do end`), e o router ainda forwarda `/api/json/*`. A API real são 23 controllers Phoenix. | `api/lib/api_web/router.ex:53-57` |
| **B2** | `docs/04-arquitetura.md` desatualizado em dois eixos: namespace `Movimento.*` (anterior ao doc 84) e deploy Fly.io `gru` (o real é Dokploy/OCI, docs 59/87). É o primeiro doc que alguém novo lê. | `docs/04-arquitetura.md §12` |
| **B3** | `GroupCapacity` materializa as linhas para fazer `length/1` em vez de um `count` agregado, e abre transação própria. Roda uma vez por `:add_participant`. | `scheduling/appointment/validations/group_capacity.ex:81` |
| **B4** | `Warm` só é usado no `Bulk`; a materialização e o ciclo de vida pagam as leituras por sessão. Assimetria entre dois caminhos de lote que fazem a mesma coisa. | `scheduling/warm.ex:51` vs `packages/sessions.ex:62` |
| **B5** | Três variantes da mesma consulta "sessões futuras não resolvidas" (`future_sessions/3`, `held_targets/2`, `Bulk.targets/3`), que precisam concordar e concordam **por convenção**. Ligado a A3. | `packages.ex:289`, `:228`, `bulk.ex:328` |
| **B6** | Quatro trechos quase idênticos de `in_clinic → transaction → Enum de escritas → case → notify`. | `packages.ex:246`, `scheduling.ex` (2×) |
| **B7** | Dois WebSockets por aba na agenda — `abrirSocket` é chamado pelo layout e pela página. O desenho natural do Phoenix é um socket com N canais. | `web/src/routes/(app)/+layout.svelte:56`, `.../agenda/+page.svelte:105` |
| **B8** | Comentário desatualizado **sobre defesa em vigor**: diz "sem rate limit" numa rota que está sob `:rate_limited_edge` e `:rate_limited_global`. Comentário que mente sobre segurança é pior que ausência de comentário. | `api/lib/api_web/controllers/patient_reply_controller.ex:89` |
| **B9** | `SlotFinder.scan_days/7` é O(dias²) (`acc ++ day_slots` seguido de `length(acc)`). Com `CAP=50` e 14 dias é irrelevante na prática — é feiura mensurável, não problema. | `waitlist/slot_finder.ex:104-114` |
| **B10** | Débitos catalogados que seguem abertos: D-1, D-2, D-4, D-5, D-6, D-7, D-8, D-9, D-10, D-12, D-15, D-16, D-17, D-18. | `50-debitos-tecnicos.md` |

---

## 3. O plano

Quatro ondas. O critério de corte: **onda 1 é o que está errado hoje**, onda 2 é o que impede
crescer, onda 3 é o que degrada sozinho, onda 4 é o que só dói com volume.

### Onda 1 — Correção

Tudo aqui é bug ou buraco provado.

| # | Achado | Solução |
| --- | --- | --- |
| 1.1 | **A3** | Em `list_package_attendances/3`, trocar `scope: scope` por `tenant: scope.clinic_id, authorize?: false`, mantendo o `in_clinic`. A operação é **sobre o pacote**, não sobre a agenda do ator; quem decide se ele pode operar já é a policy de `Package`. Alinha com as irmãs `list_sessions_including_held/3` e `list_held_sessions/2`, que já são assim. |
| 1.2 | **M3** | Calcular `more?` **antes** do `reject`. A alternativa (filtrar `pkg_hold` no SQL) foi descartada: replicaria o predicado do `HideHeld` num segundo lugar. |
| 1.3 | **M8** | `try/rescue` por clínica em `por_clinica/1`, logando `clinic_id` + erro e seguindo com 0 — o padrão que `reminder_job.ex` e `prune_attachments.ex` já usam. |
| 1.4 | **M9** | `Api.Audit.Capture` em `AvailabilityRule`, com teste cobrindo a escrita **aninhada** (é o caso que o diff do pai ignora). |
| 1.5 | **M4** | `AbortSignal.timeout` em `apiFetch`, sobreponível por `init`, com `AbortError` caindo no mesmo `{status: 0}` que o BFF já trata. |
| 1.6 | **M12** | **Decisão: manter o padrão `nao-responda@`.** Remover o `maybe_reply_to/2` morto e corrigir o `moduledoc` que promete o contrário. |
| 1.7 | **M11** | `exigirJson` nos dois `+server.ts` de pacotes. |
| 1.8 | **B8** | Corrigir o comentário. |
| 1.9 | **`[D-16]`** | Aplicar `CLIENT_IP_HEADER=CF-Connecting-IP` nos dois stacks (decisão do doc 90, pendente de operação). |

### Onda 2 — Consolidação estrutural

| # | Achado | Solução |
| --- | --- | --- |
| 2.1 | **B5** | Depois de 1.1 — nunca antes — extrair `pares_do_pacote/3` das três variantes. Unificar código com regimes de autorização diferentes esconderia o bug em vez de corrigi-lo. |
| 2.2 | **A5** | Tabela de casos em JSON lida pelos **dois** lados (ExUnit e Vitest): `cpf`, `cnpj`, `telefone`, `email`, `periodos`. É o que `docs/04 §10` prescreveu. |
| 2.3 | **M5** | `Ash.bulk_create` no fan-out; um `in_clinic` único envolvendo o laço de participantes do `Notifier`; matar o N+1 de `ja_confirmada?/1`. |
| 2.4 | **B1, B2** | ADR "a API REST é de controllers nomeados" + remover `/api/json/*`; ADR "deploy em Dokploy/OCI"; atualizar `docs/04`. |
| 2.5 | **B3, B4, B6, B9** | Lote único de refactor com a suíte como rede. |

### Onda 3 — O que degrada sozinho

| # | Achado | Solução |
| --- | --- | --- |
| 3.1 | **A2** | Fixtures geradas por teste Elixir a partir dos `*_json.ex` reais, gravadas em `contracts/`, consumidas pelos `.test.ts` no lugar dos mocks. `git diff` sujo após `mix test` = contrato mudou, e o CI reprova. Começar pelos 5 quentes: agenda, pacotes, pacientes, notificações, fila. Não precisa de codegen — precisa de **uma fonte só do exemplo**. |
| 3.2 | **M1** | Medir primeiro, com `EXPLAIN ANALYZE` **pelo caminho da aplicação** (lição do doc 35). Depois tirar a análise de dentro da transação de escrita. Plano B: janela de 12 meses com o corte **declarado na resposta** — nunca truncar em silêncio. |
| 3.3 | **M10** | Separar os dois papéis da linha: `vars` (PII → poda curta) e `provider_message_id`/`status`/`at` (prova de que se avisou → retenção longa). O mecanismo existe; falta a decisão de produto. |
| 3.4 | **M6** | Não mexer ainda: instrumentar releituras por evento e decidir pela métrica. |
| 3.5 | **A4** | Tabela `acceptances` (~2 dias). A revisão jurídica é calendário de terceiro — **disparar no dia 1**, é o maior lead time do repositório. |

### Onda 4 — Quando doer

- **M7 — horizontalidade.** Rate limit ETS→Postgres, rate limit em memória do `client-error`,
  réplicas no compose. **As três juntas ou nenhuma**: meia migração cria a ilusão do teto.
- **B7** — socket único com N canais, quando a contagem aparecer numa métrica.
- **D-6, D-7, D-8** — antivírus, URL reusável, rate limit na emissão de URL assinada. Um bloco só.
- **A1 — bus factor.** Não tem onda; é recorrente. A mitigação real não é mais documentação — já há
  100 docs. É alguém executar uma tarefa não-trivial guiado **só** pelos docs e registrar onde
  travou.

---

## 4. Execução

Preenchido conforme as ondas entram. Estado dos gates, o vermelho provado de cada conserto e o que
ficou para decisão humana.

### 4.1 Onda 1 — 2026-08-03

Diff: **19 arquivos alterados (+501 −46) e 2 novos**. Todo conserto teve o vermelho **provado por
execução**; a saída está colada abaixo.

#### Estado dos gates

| Gate | Antes | Depois |
| --- | --- | --- |
| `mix format --check-formatted` | ✅ | ✅ |
| `mix compile --force --warnings-as-errors` | ✅ | ✅ |
| `mix test` | ⚠️ 1848 · **1 falha** | ⚠️ **1854 · 1 falha** (a mesma) |
| `mix test --only rls` (como `cinetra_app`) | ✅ | ✅ **0 falhas** |
| `mix coveralls` (piso 80) | ✅ | ✅ **90,0%** |
| `npm run check` | ✅ | ✅ 0 erros, 0 avisos |
| `npm run coverage` | ✅ | ✅ **206 arquivos · 2443 testes · 93,04%** |

> **A falha do `mix test` é pré-existente e não é desta onda.** É
> `Api.Accounts.User.Changes.SyncGoogleAvatarTest`, "conta antiga que entra com Google pela primeira
> vez: busca" — `Ash.Error.Forbidden` em `register_with_google`. Verificado com `git stash`: falha
> igual no `develop` limpo (`8 tests, 1 failure` com e sem as mudanças). Veio do doc 100 (avatar do
> Google). **O `develop` está vermelho hoje por causa dela** — entra na onda 1 como item novo, §4.2.

#### O que entrou

**1.1 — A3.** O conserto virou **duas metades**, e a segunda foi decisão humana tomada no meio da
execução.

*A leitura* (`Api.Scheduling.list_package_attendances/3`) perdeu o recorte A7: passou de
`scope: scope` para `tenant: scope.clinic_id, authorize?: false`, alinhada com as irmãs
`list_held_sessions/2` e `list_sessions_including_held/3`, que já eram assim.

*A policy*: `:profissional` saiu das quatro transições do `Package` (`mark_paused`, `mark_active`,
`mark_cancelled`, `mark_completed`). A alternativa "deixar o profissional cancelar a coluna do
colega" foi descartada porque a escrita da sessão passa (deliberadamente) pela policy do
`Appointment`: o bate-volta do `Api.Packages.Bulk` já havia trocado `authorize?: false` por escrita
autorizada ali, e reabrir isso desfaria um conserto medido.

Vermelho provado, antes:

```
1) cancelar pelo profissional de UMA coluna cancela as sessões da OUTRA também
   [%{status: "agendado"}, %{status: "cancelado"}, %{status: "cancelado"},
    %{status: "cancelado"}, %{status: "cancelado"}]
2) arquivar recusa quando há sessão viva na coluna do colega
   ** (MatchError) ... %Api.Packages.Package{status: :concluido}
```

Efeito colateral que só apareceu ao rodar: com a leitura certa, `cancel_package` passou a esbarrar
em `OwnProfessionalColumn` e a estourar **`MatchError` (500)** onde o caso é 403. `lifecycle/5` e
`archive_package/2` passaram a casar o resultado de `apply_mark`/`mark_package_completed` com
`case` em vez de `{:ok, _, _} =`. Em `lifecycle/5` a transição foi **para o início** da transação,
porque `Api.Repo.rollback/1` não serve ali — a transação é aninhada na do `in_clinic/2`, e no Ecto
a de dentro não abre savepoint (o motivo chegaria como `{:error, :rollback}`).

9 testes novos, em dois `describe` marcados `@describetag :a3`.

**1.2 — M3.** `read_patient_sessions/5` calculava `more?` **depois** do `reject` das presenças com
`.appointment` nulo. Vermelho provado, antes:

```
o cartão disse que acabou com 6 sessões visíveis no banco e 4 na tela
— o `more?` foi calculado sobre a lista já filtrada
```

`more?` passou a sair da lista crua. O preço aceito é uma página curta; a alternativa (repetir o
predicado do `HideHeld` no SQL) criaria uma segunda fonte da mesma regra, que é a origem da família
de bugs das seguradas. Arquivo novo: `api/test/api/scheduling/patient_sessions_test.exs`.

**1.3 — M8.** `Poda.por_clinica/1` ganhou `rescue` por clínica, logando `clinic_id` e seguindo com
zero. Vermelho provado (a rodada morria na primeira clínica); verde com o log
`poda: falhou na clínica <uuid> (clínica com dado ruim)`.

**1.4 — M9.** `Api.Waitlist.AvailabilityRule` ganhou `Api.Audit.Capture` em
`[:create, :update, :destroy]`, e `:availability_rule` entrou no `Api.Audit.ResourceKind`. Vermelho
provado: a trilha do item vinha com **`diff: []`** depois de trocar a disponibilidade.

O enum tem **duas tripwires** que dispararam e cobraram o outro lado — as duas fizeram exatamente o
que existem para fazer:

* `capture_ligado_test.exs` (a lista espelhada e a exigência de `:destroy` no `on:`);
* `web/src/lib/audit.test.ts` (a lista `TODOS` e o teste de "ação órfã").

`web/src/lib/audit.ts` recebeu as cinco entradas: união `AuditResource`, `RESOURCE_GROUPS`,
`ACTION_LABELS`, `HEADLINES`, `RESOURCE_LABELS`.

**1.5 — M4.** `apiFetch` passou a mandar `signal: init.signal ?? AbortSignal.timeout(10_000)`. O
`try/catch` do `mutate` já converte `AbortError` no `{status: 0}` que a tela trata — não houve
caminho de erro novo.

**1.6 — M12.** **Decisão: manter o padrão `nao-responda@`.** O `maybe_reply_to/2` foi removido e o
`moduledoc` de `Api.Messaging.PatientEmails`, que anunciava "a resposta do paciente cai na clínica",
passou a registrar a decisão e o porquê: o canal de volta são o link de confirmação e a resposta de
WhatsApp, que têm trilha e opt-out — um e-mail respondido para a caixa da clínica não teria nenhum
dos dois.

**1.7 — M11.** `exigirJson` nos dois `+server.ts` de pacotes. Conferido antes de aplicar que o
`PackageCreateModal.svelte` já manda `content-type: application/json` — a guarda não quebra o
cliente real. 3 testes novos cobrindo `POST` sem content-type e com content-type de formulário.

**1.8 — B8.** Comentário do `patient_reply_controller.ex` corrigido: a rota **está** sob
`:rate_limited_edge` e `:rate_limited_global`.

#### O que NÃO entrou

* **1.9 — `[D-16]` `CLIENT_IP_HEADER=CF-Connecting-IP`.** É mudança de variável de ambiente no
  painel do Dokploy, nos dois stacks — **operação, não código**. Segue pendente.
* **A verificação por `psql` sob `cinetra_app`.** Nenhuma leitura por-tenant nova foi criada nesta
  onda (`list_package_attendances/3` já rodava dentro de `in_clinic/2` e continua), então a regra
  de `.claude/rules/migrations.md` §3 não foi acionada. O gate `:rls` cobre o que havia.

#### Duas perguntas que a execução abriu, e o que se decidiu

**A trilha do cartão do pacote passou a mostrar o pacote inteiro.** Era recortada pelo A7 enquanto
o contador `usadas` ao lado — um agregado do `Package`, e agregado não roda preparation — sempre
contou tudo: num pacote espalhado por duas colunas, o cartão desenhava quatro bolinhas ao lado de um
contador dizendo cinco. É o mesmo defeito que o filtro de canceladas de `list_sessions/2` já existia
para evitar. **Decisão de produto (2026-08-03): mostrar o pacote inteiro.** O efeito é que um
`:profissional` passa a ver que o paciente tem sessões com um colega, e em que datas.

**`:profissional` perdeu pausar/retomar/cancelar/arquivar pacote.** Inclusive em pacote 100% da
coluna dele — a regra vale para os dois casos de propósito, senão o furo do A3 voltaria pela porta
do "mas este é só meu". O `+1`/`−1` (`set_total`), criar a série e ajustar a grade **continuam** com
ele. Vale conferir na tela se algum botão do cartão precisa sumir para esse papel.

### 4.2 Item 1.10 — o `develop` vermelho (fechado no mesmo dia)

**O sintoma.** `SyncGoogleAvatarTest`, "conta antiga que entra com Google pela primeira vez: busca",
falhava com `Ash.Error.Forbidden` (`Authentication failed`) em `register_with_google`. Anterior a
esta onda; veio com o doc 100.

**A datação importa.** `git checkout 5bb8b73` (o commit que introduziu o teste) e a suíte do arquivo:
`8 tests, 1 failure`. **O teste nasceu vermelho** — não foi regressão de dependência nem de código
posterior. Entrou assim e ficou.

**O diagnóstico, e a hipótese que caiu no meio.** A rejeição vem de
`AshAuthentication.Strategy.OAuth2.UserResolver`, com a mensagem *"Email could not be verified and
an account with this email already exists"*. Ela exige duas coisas (`email_trusted?/2`): a
estratégia com `trust_email_verified?` ligado **e** o payload trazendo `email_verified`.

A primeira leitura foi que faltava a flag na estratégia — `trust_email_verified?` tem default
`false` no `oauth2.ex:259`, e o bloco `google do … end` do projeto não a liga. Isso teria sido um
bug de produção: conta criada por magic link nunca mais entraria pelo Google.

**Estava errado.** O preset do Google já a liga: `strategies/google/dsl.ex:46`,
`Custom.set_defaults(trust_email_verified?: true)`. O código de produção sempre esteve certo, e
condiz com a ADR-015 ("upsert por e-mail").

**O que era, então.** A fábrica `user_info/1` do teste não mandava `email_verified` — ou seja,
modelava um provedor que **não afirma** posse do e-mail, que é justamente o caso que o
AshAuthentication recusa de propósito. A fábrica ganhou `"email_verified" => true`, que é o que o
Google de fato manda.

**E ganhou um teste que faltava.** O caminho de recusa não tinha nenhum: "conta antiga + e-mail NÃO
verificado: recusa, não faz upsert". Ele existe para que a flag não seja lida como "confia no
e-mail" — é "confia na **afirmação** de que o e-mail foi verificado", e sem afirmação não há
confiança. Sem ele, afrouxar essa metade passaria em silêncio, e o efeito seria takeover de conta.

**Depois:** `mix test` → **1855 testes, 0 falhas**. O `develop` está verde.

> Lição para o método, e vale além deste caso: **fábrica de teste que não representa o produtor real
> do dado produz vermelho falso** — e vermelho falso é caro de duas formas. Ou some no ruído (o
> commit entrou com ele), ou manda consertar produção que não está quebrada (foi o que quase
> aconteceu aqui). O `user_info` do teste tem de ser o que o Google manda, não o mínimo que a ação
> aceita.

### 4.3 Onda 2 — 2026-08-03

#### 2.1 — B5, as três cópias viram uma

`Api.Packages.Targets.pares/3` passa a ser o ponto único de "quais sessões deste pacote".
`future_sessions/3`, `held_targets/2` e `Bulk.targets/3` só declaram o predicado. **−48/+25 linhas.**

Duas notas que valem além do refactor:

* **A ordem importava e não estava garantida.** A massa ordenava por `starts_at` (o escopo
  `:a_partir_desta` depende disso); o ciclo de vida não. Agora os dois ordenam — de graça, já que a
  lista está na memória — e a ordem das escritas deixa de depender do que o Postgres devolveu.
* **Só deu para fazer depois do A3.** Enquanto as duas leituras tinham regimes de autorização
  diferentes, juntá-las teria escondido o bug em vez de corrigi-lo. Ordem, aqui, era requisito.

#### 2.2 — A5, o contrato que o `docs/04 §10` pediu

`contratos/regras-espelhadas.json`, na **raiz** (não é de nenhum dos dois lados), com **49 casos**
em cinco regras: CPF, CNPJ, telefone canônico, forma mínima do e-mail e períodos do dia. Lido por
`api/test/api/paridade_espelhada_test.exs` e `web/src/lib/paridade-espelhada.test.ts`.

O container do `web` ganhou o `./:/repo:ro` que o `api` já tinha. Os dois testes procuram em `../`
e em `/repo/` e **falham** se não acharem, e os dois têm um teste da *forma* do arquivo — seção
renomeada ou esvaziada passaria a exercitar zero casos e reportaria verde.

**Provado que morde**, mutando cada lado (a regra do projeto: mute a regra e confira o vermelho):

| Mutação | Resultado |
| --- | --- |
| TS: remover a guarda de dígitos repetidos do `isValidCpf` | 2 falhas (`111.111.111-11`, `000.000.000-00`) |
| Elixir: remover o `starts_with?("55")` do `normalizar(:whatsapp, _)` | 1 falha (`119876543210` → `+119876543210`) |

O caso mais valioso do contrato é o do estrangeiro: `+1 415 555 0000` → `+5514155550000`, nos dois
lados. É **errado como número** e **certo como paridade** — o servidor não tem guarda de estrangeiro
nesse caminho, e um cliente que tivesse recusaria o que o banco aceita. Sem o contrato, "consertar"
o lado TS parece melhoria e é regressão.

#### 2.3 — M5: dois terços do achado não sobreviveram à verificação

O achado dizia três coisas. **Uma é verdade, duas não são.**

| Alegação | Veredito |
| --- | --- |
| `Fanout.notify/6` faz 1 `create_notification` + 1 broadcast por destinatário | ✅ verdade — é o laço, visível no código |
| "uma transação própria por participante" no `Dispatch` | ❌ **falso.** `disparar/3` já roda dentro do `Api.Repo.with_clinic` de `avisar/2`, e o `in_clinic/2` de dentro do `Dispatch` é transação **aninhada**: no Ecto ela não abre savepoint, junta-se à de fora. Não são N transações |
| N+1 em `ja_confirmada?/1`, com `Ash.exists?` por participante | ❌ **falso.** A função **não existe** no repositório (`rg ja_confirmada` → nada; `rg 'Ash.exists?' api/lib/api/messaging/` → nada) |

Com isso, a estimativa que justificava a mudança ("~32 idas ao banco numa turma de 8") não se
sustenta. Sobra a primeira alegação — e ela é sobre um N pequeno: os destinatários são a equipe
operacional da clínica (`owner`·`admin`·`recepcao`), tipicamente 2 a 6 pessoas, num caminho
pós-commit.

**Decisão: não trocar por `Ash.bulk_create`.** O `notify/6` de hoje tem `rescue` por destinatário
(um registro ruim não derruba os outros) e um `Feed.broadcast_new` por notificação, que é o que faz
o sino subir. Trocar isso por um `bulk_create` custa a isolação de erro e a granularidade do
broadcast para poupar meia dúzia de INSERTs — troca ruim, e a medida que a justificaria era de um
achado que não se confirmou.

**Fica registrado como não-feito, com o porquê**, e não como pendência: refazer a análise daqui a
seis meses e reencontrar "fan-out é O(n)" sem esta nota faria alguém pagar o custo.

> O que este item ensina sobre o método: **achado de análise estática é hipótese até ser medido.**
> Três dos achados desta rodada caíram na verificação — o M2 (leitura fora da GUC, que tinha
> `in_clinic`), o 1.10 (que parecia bug de produção e era fábrica de teste) e dois terços do M5. A
> análise continua valendo pelo que ela **aponta**; o que ela afirma precisa passar pelo `psql`,
> pelo `QueryCounter` ou pelo `git checkout`.

#### 2.4 — B1 e B2: as duas eram lacunas de **registro**, não de código

Nos dois casos o código já estava certo; velha estava a documentação que alguém novo lê primeiro.

* **B1** — a remoção do AshJsonApi **já tinha sido feita** pelo doc 96 (M-2, 2026-08-01): saíram
  as rotas `/api/json/*`, `Api.Meta`, `ApiWeb.AshJsonApiRouter`, as deps `ash_json_api` e
  `open_api_spex`, o parser do endpoint e o plug `RequireScope`. O que faltava era a **ADR** — a
  ADR-002 seguia anunciando "expondo AshJsonApi". Registrada como **ADR-027**, com a consequência
  a vigiar escrita nela: sem esquema gerado, o contrato BFF↔API é mantido à mão (o A2).
* **B2** — a metade sobre deploy **já tinha ADR**: a ADR-023 (2026-07-31) substituiu a ADR-008.
  O que estava velho era o `docs/04 §12`, que ainda desenhava Fly.io `gru` nos três ambientes. A
  tabela nova traz o real e diz em voz alta o que a antiga escondia: **instância única** dos três
  serviços, sem réplica, e por quê. Os nomes de módulo `Movimento.*` viraram `Api.*`; os links
  para `interface/Movimento.dc.html` ficam, porque o protótipo ainda se chama assim.

#### 2.5 — dos quatro, um estava feito, um revelou bug e dois não valem

| # | Veredito |
| --- | --- |
| **B9** — `SlotFinder` O(dias²) | ✅ **já estava feito.** O doc 96 (P-1) trocou o `acc ++ day_slots` + `length(acc)` por acumulador invertido com a contagem ao lado. Achado obsoleto |
| **B6** — o molde `in_clinic → transaction → notify` | ✅ feito — e **revelou um bug meu**, ver abaixo |
| **B3** — `count` agregado no `GroupCapacity` | ❌ **não feito, de propósito.** As linhas contadas são as presenças de **um** bloco, limitadas pela capacidade da turma (tipicamente ≤ 10): materializar dez linhas para contá-las não é problema. E há risco real: o `count_participants/2` de hoje passa pela **read action**, então as preparations rodam — `HideHeldAttendances` tira as seguradas da conta. Um `Ash.count!` sobre query crua não as rodaria, e presença segurada por pacote pausado passaria a ocupar vaga. Ganho nulo, risco de mudança de comportamento |
| **B4** — `Warm` na materialização e no ciclo de vida | ⏭️ **movido para a onda 4.** É ganho de constante, e o próprio plano já o tinha posto lá (S18: "vale quando pacotes de 100+ sessões forem comuns"). Estava na onda 2 por erro meu de escopo |

**O bug que o B6 revelou.** O conserto do A3 (§4.1) tratou `lifecycle/5` e `archive_package/2` e
**deixou `resume_package/2` de fora** — ele é a única das quatro transições que não passa pelo
`lifecycle/5`, e casava `{:ok, _, _} = mark_package_active(...)` do mesmo jeito. Com
`:profissional` fora do ciclo de vida, o botão **Retomar** respondia **500** em vez de 403.
Vermelho provado (`MatchError` sobre `%Ash.Error.Forbidden{}` de `Package.mark_active`), teste
novo, e o conserto é a própria extração: `transacao_com_notificacoes/2` é o molde único, e a
transição passou a vir primeiro também no `resume_package/2`.

> Vale anotar por que ele escapou: os quatro testes da §4.1 cobriram pausar, cancelar e arquivar —
> as três que passam por `lifecycle/5`. **A quarta transição tinha caminho próprio, e o teste foi
> escrito olhando o conserto, não a lista de transições.** A extração do B6 é o que tornou a
> assimetria visível, o que é um argumento a favor de fazer o DRY: duplicação não é só custo de
> manutenção, é lugar onde um conserto não chega.

#### Placar da onda 2

| Item | Resultado |
| --- | --- |
| 2.1 (B5) | feito — `Api.Packages.Targets`, −48/+25 |
| 2.2 (A5) | feito — 49 casos, mordida provada nos dois lados |
| 2.3 (M5) | **não feito** — 2 de 3 alegações falsas; decisão registrada |
| 2.4 (B1, B2) | feito — ADR-027 + `docs/04`; o código já estava certo |
| 2.5 (B6) | feito — e achou o `resume_package` |
| 2.5 (B9) | já estava feito (doc 96) |
| 2.5 (B3) | **não feito** — ganho nulo, risco real |
| 2.5 (B4) | movido para a onda 4 |

Gates ao fim da onda: `mix test` **1862 · 0 falhas** · `--only rls` 0 falhas · `coveralls` **90,0%**
· `npm run check` 0 erros · `npm run coverage` **2497 testes · 93,04%**.

> **Dos 26 achados da análise, 6 não sobreviveram à verificação** (M2, B1, B9, dois terços do M5,
> e o diagnóstico inicial do 1.10) e 2 foram recusados com justificativa (B3 e a parte viva do M5).
> Isso não desqualifica a análise — ela apontou o A3, o M3, o M8, o M9 e o A5, que eram reais e
> caros. Diz que **a taxa de falso-positivo de uma leitura estática do repositório é alta o
> bastante para que "medir antes de consertar" seja regra, não zelo.**

### 4.4 Onda 3 — 2026-08-03

A onda do "que degrada sozinho". Duas decisões de produto foram tomadas **antes** de a execução
começar, e as duas mudaram o desenho do que entrou:

* **3.3 (M10)** — o mecanismo de poda entra pronto e **desarmado**, sem número e sem cron, até o
  jurídico decidir a régua. É o que o `[D-11]` já vinha dizendo desde 2026-07-28;
* **3.5 (A4)** — o aceite fica em **campos no `User`** (`termos_aceitos_em`/`termos_versao`), como
  o `[D-14]` desenhou, e não na tabela `acceptances` que o plano previa.

#### Estado dos gates

| Gate | Antes (fim da onda 2) | Depois |
| --- | --- | --- |
| `mix format --check-formatted` | ✅ | ✅ |
| `mix compile --force --warnings-as-errors` | ✅ | ✅ |
| `mix test` | 1862 · 0 falhas | ✅ **1896 · 0 falhas** |
| `mix test --only rls` (como `cinetra_app`) | 0 falhas | ✅ 0 falhas (ver a nota) |
| `mix coveralls` (piso 80) | 90,0% | ✅ **89,7%** |
| `npm run check` | 0 erros | ✅ 0 erros, 0 avisos |
| `npm run coverage` | 2497 testes · 93,04% | ✅ **207 arquivos · 2522 testes · 93,04%** |
| contrato BFF↔API depois de `mix test` (gate novo) | — | ✅ fixture idêntica byte a byte entre rodadas |

> **Uma falha isolada no gate `:rls`, não reproduzida.** A primeira execução do `--only rls` desta
> onda acusou 1 falha; as **oito** seguintes vieram verdes, e o rastro da primeira não foi
> capturado. Fica registrado em vez de omitido: não sei o que falhou. Se reaparecer, o primeiro
> lugar a olhar é resíduo de estado entre execuções — o gate roda a suíte inteira com filtro, e o
> sandbox é a única coisa entre um teste e o outro.

#### 3.1 — A2: o contrato BFF↔API deixa de ser mantido a olho

`api/test/api_web/contrato_bff_test.exs` monta um mundo pequeno e completo, **atravessa o roteador
de verdade** e grava em `contratos/bff/*.json` o corpo que a API respondeu. São **11 amostras** nos
cinco recursos quentes: agenda (janela, bloco), pacientes (lista, ficha, histórico), pacotes (lista,
trilha, prévia), notificações (caixa, badge) e fila (lista). Os cinco `.test.ts` do BFF passaram a
ler essas fixtures no lugar do JSON que inventavam, e cada um ganhou um `describe("contrato com a
API")` que **declara os campos que aquele lado lê**.

A metade difícil não foi gerar — foi **determinismo byte a byte**, porque o gate é um `git diff`. Um
único valor volátil deixaria o arquivo sujo em toda rodada e o sinal viraria ruído em uma semana.
`Api.ContratoBff` normaliza três coisas:

| o que | vira | por quê |
| --- | --- | --- |
| uuid | `00000000-…-000N`, por ordem de aparição | o mesmo id em duas amostras recebe o mesmo número, então `patient_ids` continua apontando para o paciente do sidecar |
| carimbo a menos de 5 min da geração (`agora`, `inserted_at`) | instante fixo | é a hora em que a suíte rodou, não o contrato |
| datas do mundo montado | deslocadas para a **semana-âncora** | o mundo nasce em `âncora + 7k` semanas — sempre no futuro, sempre a mesma segunda-feira. Sem isso, ou a fixture muda de dia todo dia, ou apodrece numa data que vira passado |

**Provado determinístico**, e por comparação de bytes, não por "o git não reclamou": a fixture da
primeira rodada foi guardada e conferida contra a que a **suíte inteira** gravou quase quatro horas
depois — `diff -r` sem diferença. Vale a distinção, porque `git status` com arquivo ainda
não-rastreado diria "limpo" mesmo se o conteúdo tivesse mudado.

**Provado que morde**, pela regra do projeto (mute a regra e confira o vermelho): renomeei `usadas`
para `usadas_agora` em `ApiWeb.PackagesJSON`, regerei a fixture e rodei o BFF:

```
Error: pacotes/lista_do_paciente → packages[0]: a API não manda mais `usadas`.
Presentes: acabando, appointment_type_id, cor, data_inicio, falta_punitiva, grade, id, nome,
restantes, sessoes, status, total, usadas_agora.
```

Vale reparar em **qual** teste ficou vermelho: 1 dos 27 do arquivo. Os outros 26 continuaram verdes
porque comparam a fixture consigo mesma — o que confirma que a asserção de campos é a peça que
carrega o peso, e que trocar o mock pela fixture, sozinho, não teria pegado nada.

O gate do CI é um passo novo no job `api`, depois do `mix coveralls`: `git add --intent-to-add` (um
recurso novo chega como arquivo não-rastreado, e `git diff` sozinho é cego para esses) seguido de
`git diff --exit-code -- contratos/`.

Duas notas de escopo:

* **`GET /api/waitlist/slots` ficou de fora, e é decisão.** O `SlotFinder` varre a partir de
  **agora**: as datas que ele devolve mudam com o dia em que a suíte roda, e a fixture ficaria suja
  todo dia. Aquele `.test.ts` segue com corpo escrito à mão, e a nota está no próprio arquivo;
* o `docker-compose.yml` ganhou `./contratos:/contratos` **gravável** no serviço `api` — o
  `/repo:ro` continua como estava. O caminho é o mesmo nos dois ambientes: a suíte roda com cwd
  `/app`, e `/app/../contratos` é o ponto de montagem em dev e o checkout ao lado no CI.

#### 3.2 — M1: medido primeiro, e o conserto não foi o que o plano dizia

**A medição, pelo caminho da aplicação.** Clínica de volume com **10.000 blocos futuros** e 4
profissionais; `future_conflicts/2` chamado pelo código de produção, 5 repetições, mediana:

| mudança | antes | depois |
| --- | --- | --- |
| `clinic_hours` (semana inteira) | 268,0 ms | **230,3 ms** |
| `professional_hours` (1 profissional) | 264,5 ms | **50,5 ms** |
| `clinic_exception` (1 dia) | 274,7 ms | **6,7 ms** |
| `professional_exception` (1 dia) | 235,1 ms | **6,7 ms** |

E o perfil de para onde ia o tempo, no caso mais recortável (folga de um profissional num dia, que
afeta 6 blocos):

```
future_conflicts inteiro : 372,0 ms
soma do tempo em SQL     : 106,0 ms  (40 consultas a appointments)
resto (BEAM)             : 266,0 ms
```

As 40 consultas são o `stream?` paginando de 250 em 250. Os 266 ms são **montar structs do Ash que
o filtro seguinte descartava**. E o `EXPLAIN (ANALYZE, BUFFERS)` — feito sobre a string que o Ash
emitiu, capturada do telemetry do repo, nunca sobre SQL digitado à mão (lição do doc 35) — mostrou
`Index Scan using appointments_clinic_id_starts_at_index`, 0,2 ms por página. **O plano da consulta
estava certo; errado era o volume pedido.**

**O conserto.** `ImpactAnalysis.recorte/1` passa a declarar o que a mudança pode alcançar
(`%{date:, professional_id:}`) e `Api.Scheduling.agendamentos_futuros/4` transforma isso em filtro
SQL. O recorte mora no motor puro, ao lado do `afetado_por?/2`, de propósito: são a mesma regra
vista de dois lados, e é o par que não pode divergir — recortar a mais na leitura **esconde
conflito real**, que é o modo de falha caro deste gate. A `clinic_hours` continua lendo tudo, e o
teste diz isso em voz alta: recortá-la exigiria converter fuso dentro do SQL.

**O que eu NÃO fiz, e por quê.** O plano dizia "tirar a análise de dentro da transação de escrita".
Não tirei. A análise roda ali **de propósito**: é o recheck do A3/D12, e entre analisar e gravar
cabe um agendamento novo — o mesmo motivo pelo qual `CheckAvailability` confere o expediente dentro
da ação de agendar. Tirá-la de lá troca 260 ms de transação por uma corrida que o desenho fechou de
propósito. Com a medição na mão, o problema era o **tamanho da leitura**, não o lugar dela; e
depois do recorte os dois caminhos que a recepção mais usa (feriado e folga) custam 7 ms dentro da
transação. Se um dia a `clinic_hours` incomodar, o caminho é reduzir o que ela lê, não afrouxar o
gate.

**A segunda metade do M1 caiu na medição.** "O `ImpactAnalysis.conflicts/4` roda `day_periods/3`
duas vezes por agendamento afetado" é verdade. A memoização por `{profissional, dia}` foi
**construída, medida e descartada**: no pior caso (semana da clínica, 1.400 afetados, 2.800 chamadas
caindo para 280 — 10× menos), a mediana foi de **230,9 ms para 230,3 ms**. Dentro do ruído, e há
razão estrutural para isso: **afetados ≤ carregados**, e carregar uma linha custa ordens de grandeza
mais que simular um dia — a simulação não tem como dominar. Fica registrado no código, com o
número, para ninguém pagar a complexidade de novo pelo mesmo nada.

#### 3.3 — M10: dois relógios sobre a mesma linha, e o cron fica desligado

`Api.Housekeeping.PruneMessages` separa os dois papéis que a linha de `messages` acumula:

* **a prova de que a clínica avisou** (`kind`, `canal`, `status`, `provider_message_id`, carimbos) —
  foi por ela que o recurso dispensou o `AshPaperTrail`: o registro **é** o histórico;
* **o dado pessoal do titular** (`vars` com o nome do paciente, `destino` com o telefone/e-mail
  congelado) — dado parado, que ninguém lê depois do envio.

A janela curta **anonimiza** (`UPDATE`, a linha fica e continua provando o que aconteceu); a longa
**apaga**. `Api.Housekeeping.Poda` ganhou `atualizar_em_lote/5`, o irmão do `em_lote/4` — mesma
disciplina de GUC por lote, porque um `UPDATE` sem GUC toca zero linha em silêncio.

**O número não está no código, e isso é o desenho.** Sem as duas chaves em config o job registra um
aviso e devolve zero, sem tocar em nada — e ele **não está no crontab**. Um default embutido faria
o oposto do que o `[D-11]` decidiu: no dia em que alguém escrevesse a linha do cron, a régua de
ninguém entraria em produção calada. Meia política (uma chave só, ou PII com janela maior que a da
linha) também é recusada.

**RLS provada por `psql`, sob o role restrito** — é caminho de escrita novo, e o gate `:rls` não
alcança isso (`.claude/rules/migrations.md` §3):

```
cinetra_app, SEM a GUC : UPDATE 0
cinetra_app, COM a GUC : UPDATE 23
postgres (controle)    : 23 linhas na clínica
```

#### 3.4 — M6: instrumentado, não mexido

O plano dizia "não mexer ainda: instrumentar releituras por evento e decidir pela métrica". Foi o
que aconteceu, e a razão de não mexer ficou mais clara ao escrever: a releitura por assinante é o
que faz o recorte A7 valer no WebSocket **com uma autoridade só** (`OwnAgendaOnly`). Trocá-la por
uma leitura compartilhada exige reimplementar o recorte no canal — a segunda cópia de uma regra de
vazamento. Isso só se paga com número na mão.

Três séries, no plugin `Api.PromEx.Agenda`:

```
cinetra_agenda_broadcasts_total                         # quantas publicações
cinetra_agenda_channel_entregas_total{modo,releitura}   # quantos canais trataram
cinetra_agenda_channel_releitura_duration_milliseconds  # quanto custou cada releitura
```

São **duas** contagens porque a razão entre elas é a resposta: `entregas / broadcasts` = assinantes
por tópico. Com um contador só não dá para distinguir "muita gente na tela" de "muita escrita na
agenda" — dois problemas com remédios opostos. O rótulo `releitura` separa quem paga banco (modo
`block`) de quem só empurra sinal (`signal` e `appointment_excluded`), e sem ele o único número que
interessa viria inflado.

#### 3.5 — A4: o aceite deixa de ser presumido

`users.termos_aceitos_em` e `users.termos_versao`, carimbados pelo **BFF** logo depois da sessão
assinada, nos dois callbacks de login (`/auth/callback` e `/auth/user/google/callback`), via
`POST /api/auth/terms-acceptance`. Três decisões que valem além do item:

* **a versão vem do BFF.** O texto legal mora em `web/src/lib/legal.ts`; uma constante espelhada do
  lado Elixir seria o quinto par do A5 — e o que apodreceria em silêncio seria justamente o registro
  legal, com o banco guardando aceite de uma versão que ninguém leu;
* **idempotente por versão.** Reaceitar a mesma versão não reescreve a data do primeiro aceite;
  versão nova carimba de novo. Sem isso, `termos_aceitos_em` viraria "último login" — outro dado, e
  que não prova nada;
* **nunca derruba o login.** Falha ao registrar é registro faltando, que o próximo login corrige.
  Trocar isso por uma pessoa sem acesso seria péssimo negócio.

O caminho do Google é justamente o que uma caixa de seleção no `/criar-conta` **não** alcançaria (o
botão é um `<a>` de navegação completa, doc 76 §1) — e é a razão de o carimbo morar depois da
sessão, e não no formulário.

#### O que NÃO entrou

* **A revisão jurídica dos documentos legais (`[D-13]`)** — é calendário de terceiro, não código, e
  segue sendo o maior lead time do repositório. O mecanismo de aceite já grava; o que ele grava
  ainda aponta para um texto com `[RAZÃO SOCIAL]`, `[CNPJ]` e `[COMARCA/UF]` em aberto. **Registrar
  aceite da versão 1.0 só tem valor quando a 1.0 for o texto definitivo** — disparar a revisão é a
  próxima ação, e ela é humana.
* **O número da retenção de `messages`** — por decisão registrada acima, o job entra desarmado.

#### Placar da onda 3

| Item | Resultado |
| --- | --- |
| 3.1 (A2) | feito — 11 amostras, 5 `.test.ts` religados, gate no CI, mordida provada |
| 3.2 (M1) | feito — recorte no SQL: 372 → 7 ms nos caminhos recortáveis |
| 3.2 (memo do `day_periods`) | **não feito** — construído, medido (231 → 230 ms) e descartado |
| 3.2 (tirar da transação) | **não feito, de propósito** — reabriria a corrida do A3/D12 |
| 3.3 (M10) | feito e **desarmado** — mecanismo pronto, sem número e sem cron |
| 3.4 (M6) | feito — três séries; o desenho segue como estava, por decisão |
| 3.5 (A4) | feito — `[D-14]` pago; `[D-13]` segue aberto (não é código) |
