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

#### O que falta da onda 2

* **2.4** — as ADRs que faltam (controllers nomeados vs. AshJsonApi, deploy em Dokploy), remover
  `/api/json/*` do router, atualizar `docs/04` (namespace `Movimento.*` e Fly.io).
* **2.5** — as limpezas: `count` agregado no `GroupCapacity`, `Warm` na materialização e no ciclo
  de vida, o molde `in_clinic → transaction → notify` repetido 4×, o `SlotFinder` O(dias²).
