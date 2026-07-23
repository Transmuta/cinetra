# 30 — Decisões pendentes da Agenda (consolidação)

> ⚠️ **Parcialmente desatualizado (2026-07-23).** Vários itens abaixo **já foram resolvidos** em
> fatias posteriores — verificados como feitos: **D-E, D-P, D-D, D-Q, D-N** (boa parte pelo commit
> `0a07f4c`), além de **D-M, D-F, D-A, D-C, D-S** (Ondas 1–2) e **D-G, D-H, D-J, D-K, S1**
> (Frente 3) e **F3, F4, F6, D-L** (Frente 4). **Confirme no código antes de reabrir qualquer
> item daqui.** O status corrente de
> execução vive em [`35-plano-execucao-backlog.md`](35-plano-execucao-backlog.md).

Varredura de **todo o contexto de agenda** — o doc de desenho [`25-agenda.md`](25-agenda.md) (as
cinco Entregas e o §9/§10) e os cinco bate-voltas [`26`](26-auditoria-bate-volta-agenda.md),
[`27`](27-auditoria-bate-volta-visoes.md),
[`28-ciclo`](28-auditoria-bate-volta-ciclo-de-vida.md),
[`28-tempo-real`](28-auditoria-bate-volta-tempo-real.md) e
[`29`](29-auditoria-bate-volta-fila-de-espera.md) — reunindo **o que ainda não foi decidido, foi
deferido, ou foi resolvido com "não feito" que aguarda um sim/não humano**.

As Entregas 1–5 estão **construídas e auditadas**. Nada aqui bloqueia o que existe; é a lista de
pontas que ficaram em aberto, para priorização.

Legenda de estado:
- 🔴 **Decisão de produto/negócio em aberto** — ninguém decidiu ainda; precisa de você.
- 🟡 **Deferido** — decidido como "não agora", backend pode estar pronto; vira fatia própria.
- 🟢 **Fora de escopo (v1)** — decisão *já tomada* de não fazer; listado para não parecer esquecido.
- 🔧 **Dívida técnica / arquitetura** — conserto conhecido, custo medido, espera decisão.

---

## 1. Decisões de produto / compliance — RESOLVIDAS (2026-07-21) ✅

**As cinco foram decididas com o humano em 2026-07-21.** Registro abaixo, com o desdobramento de
cada uma (algumas viram tarefa de implementação, outras fecham como "não fazer").

| # | Pergunta | **Decisão (2026-07-21)** | Desdobramento | Origem |
| --- | --- | --- | --- | --- |
| P1 | O papel `profissional` deve enxergar a escala/coluna dos colegas? | **NÃO — profissional só vê a própria agenda.** A escala do colega (coluna vazia no Dia, `0`/capacidade no nome do colega em Semana/Mês) **some**. | Vira **tarefa de implementação**, não mais pergunta: recortar `list_professionals` por papel quando `papel == :profissional` (hoje não é recortada — só os *agendamentos* são, via A7/`OwnAgendaOnly`). Alcança Dia + Semana + Mês + `/api/availability` **de uma vez**. Ver **T-P1** em §4. | [`25 §8b`](25-agenda.md), [`27 (e)`](27-auditoria-bate-volta-visoes.md) |
| P2 | Prazo de retenção da trilha de auditoria. | **Não tratar retenção agora.** Guardar para sempre segue como default consciente. | Encerrada — sem ação nesta fase. | [`26 §7.4`](26-auditoria-bate-volta-agenda.md), [`25 §11.3`](25-agenda.md) |
| P3 | `obs` retido em claro na trilha (expurgo/redação?). | **Não tratar agora** (coerente com P2 e A-D13: manter em claro). | Encerrada — sem ação nesta fase. | [`26 §5.2 (d)`](26-auditoria-bate-volta-agenda.md) |
| P4 | Como atender exclusão LGPD com a trilha tornando o agendamento indeletável? | **Podemos excluir — e será exclusão de verdade** (hard delete), não anonimização. Não existe `destroy` hoje (por design); a FK do paper-trail sem `ON DELETE` faz o `DELETE` cru falhar. É uma **fatia de eliminação do titular a construir**, ancorada no **Paciente** (onde mora o dado pessoal), não no agendamento isolado. | Vira **fatia futura** (não uma dívida escondida). **Desenho fechado:** `destroy` que **apaga de verdade**, com `ON DELETE` (ou destroy da versão antes) **podando a trilha** junto — some o histórico do titular apagado, que é o que a exclusão LGPD exige. Ver **F8** em §2. | [`26 §5.1 (c)`](26-auditoria-bate-volta-agenda.md), [`26 §8.6`](26-auditoria-bate-volta-agenda.md) |
| P5 | Qual a duração máxima de um agendamento? | **Não há teto — a duração vem dos tipos de atendimento** (que também não têm máximo). | **Decide o conserto do D-A:** sem teto, a varredura do `:in_range` **não** pode ser fechada por `from − duração_máxima`; tem que ser o **índice GiST não-parcial** sobre o range. Some a ambiguidade que travava o D-A — sobra um caminho técnico só. Ver **D-A** em §4. | [`27 (a)`](27-auditoria-bate-volta-visoes.md), [`28-tempo-real (c)`](28-auditoria-bate-volta-tempo-real.md) |

---

## 2. Funcionalidades desenhadas e deferidas 🟡

Decididas como "sim, mas depois" — várias com **backend já pronto e testado**, faltando só a UI ou
o gatilho.

| # | Item | Estado | Origem |
| --- | --- | --- | --- |
| F1 | **UI falta → "quem cabe aqui?"** — gatilho no drawer + modal de oferta a partir de uma falta. | Backend `who_fits` + `/candidates` **pronto e testado**; falta só a UI. | [`25 §9 (E5)`](25-agenda.md), [`29 §5`](29-auditoria-bate-volta-fila-de-espera.md) |
| F2 | ~~**Tela `/configuracoes/auditoria`** — exibir a trilha.~~ **CONSTRUÍDA.** `TrailMixin` (policies owner·admin + `read :audit_log` paginada), `list_audit_log/2` (feed + diff encadeado do `:changes_only` + enriquecimento autor/registro), `GET /api/audit`, tela SvelteKit (`FieldDiff` novo). Bate-volta feito: [`32`](32-auditoria-bate-volta-tela-auditoria.md) — 1 seg MÉDIO corrigido (uuid malformado → 422, era 500), 2 gargalos estruturais viraram decisão (D-Aud1/D-Aud2 abaixo). | [`25 §11`](25-agenda.md), [`32`](32-auditoria-bate-volta-tela-auditoria.md) |
| F3 | ~~**`cancel_reason` na UI**~~ **FEITO** (Frente 4): cancelar abre confirmação com motivo **opcional**, que viaja no form. Opcional de propósito — exigir motivo faz digitar "asdf" para conseguir cancelar. | [`25 §8d`](25-agenda.md), [`35`](35-plano-execucao-backlog.md) |
| F4 | ~~**Indicador ao vivo "alguém está oferecendo esta vaga"**~~ **FEITO** (Frente 4) — e **sem `Presence`**: a fonte é o próprio `SlotHold` (a linha que a constraint enxerga), o `GET /api/waitlist` devolve as reservas vivas com quem segura, e o notifier emite `slot_held`/`slot_released`. Presence diria "fulano está com o modal aberto" (morre com o processo); o hold diz "reservada até tal hora" e sobrevive a um refresh. | [`25 §8e (D-E5.3)`](25-agenda.md), [`35`](35-plano-execucao-backlog.md) |
| F5 | **`Phoenix.Presence` "quem está vendo este dia"** (09 §7.4). | Fora das Entregas 3 e 4; não está no protótipo. | [`25 §9 (E3/E4)`](25-agenda.md) |
| F6 | ~~**Paginação da fila de espera.**~~ **FEITO** (Frente 4): 50/página. Junto vieram três consequências obrigatórias — a ordem de prioridade virou ordenação de **banco** (`prio_rank`), o filtro `?prio=` saiu do cliente para o servidor, e as contagens da sidebar passaram a vir do servidor. `/waitlist/slots` aceita a mesma janela. | [`29 §5`](29-auditoria-bate-volta-fila-de-espera.md), [`35`](35-plano-execucao-backlog.md) |
| F7 | **Confirmar/iniciar atendimento como ações reais** (`confirmar`, `iniciar_atendimento`). | Hoje `confirmado`/`em_atendimento` só nascem de seed; "Enviar confirmação" é só toast. Depende de decisão de produto: *o que "confirmar" significa sem WhatsApp? `em_atendimento` deriva do relógio?* | [`25 §8d (D-E4.1)`](25-agenda.md) |
| F8 | **Eliminação de dados do titular (LGPD)** — resolução do **P4**. Fatia a construir, ancorada no **Paciente**. Nada existe hoje (sem `destroy`; FK do paper-trail sem `ON DELETE`). | Backend **não** iniciado. **Desenho decidido: hard delete** — `destroy` que apaga de verdade + `ON DELETE` podando a trilha junto (anonimização descartada). Atenção: contraria a política geral "sem hard delete" do projeto ([`25 §3`](25-agenda.md)) — é a exceção deliberada para o direito de eliminação; restringir por policy a owner/admin e provar sob RLS. | [`26 §5.1 (c)`](26-auditoria-bate-volta-agenda.md), P4 acima |

**Verificação ao vivo pendente (não é decisão, é tarefa):** o gesto do **arraste ponta-a-ponta**
(ponteiro real no browser) nunca foi clicado — a matemática e o endpoint estão cobertos por teste,
mas o arrasto num browser fica como verificação a fazer ([`25 §9 (E4)`](25-agenda.md)).

---

## 3. Explicitamente fora de escopo na v1 🟢

Decisões *já tomadas* de não fazer. Listadas para rastreabilidade — os ganchos de schema já existem
onde precisam.

| # | Item | Gancho pronto / nota | Origem |
| --- | --- | --- | --- |
| V1 | **Pacotes** (Fatia 3): série, débito, falta punitiva, pausar/retomar. | `package_id` nullable em `Appointment` **e** `Attendance`, `pkg_hold`, e o ponto único de leitura filtrável. | [`25 §9 FORA`](25-agenda.md) |
| V2 | **Prontuário** (ADR-013/D16). | Paciente é "mínimo, só o suficiente para selecionar um nome". | [`25 §9 FORA`](25-agenda.md) |
| V3 | **Financeiro / preço.** | Faturamento histórico exige preço vigente na data — não inventar o modelo aqui. | [`25 §9 FORA`](25-agenda.md) |
| V4 | **Salas / equipamentos** (GAP-15, v2). | Muda a exclusion constraint de "por profissional" para "por recurso" — a alteração de schema mais cara do sistema. Instrução explícita: **não decidir por palpite**. | [`25 §9 FORA`](25-agenda.md), [`25 §8 (A-D5)`](25-agenda.md) |
| V5 | **Conflito por paciente bloqueante** (hoje só avisa). | Revisitar junto de V4 (recurso). Bloquear atrapalha o caso legítimo de sobreposição por remarcação. | [`25 §8 (A-D5)`](25-agenda.md) |
| V6 | **Relatórios** (Fatia 9). | Bloqueados por A-D12 (a fórmula única de ocupação já está fechada). | [`25 §9 FORA`](25-agenda.md) |
| V7 | **`futureConflicts` ligado** (Fatia 7). | Estender D12 (que fala do **horário do profissional**) para clínica/exceção é **decisão nova**; e RN-16 esqueceu o terceiro consumidor (`addHoliday`), que ainda tem precedência própria na simulação. | [`25 §9 FORA`](25-agenda.md) |

---

## 4. Dívida técnica / arquitetura aguardando decisão 🔧

Custos conhecidos (vários **medidos**), conserto identificado, sem aplicar — porque a correção é
decisão de arquitetura ou toca infra/código já entregue.

### Tarefa de implementação nascida da decisão do P1

| # | Tarefa | Escopo | Origem |
| --- | --- | --- | --- |
| T-P1 | ~~**Recortar `list_professionals` por papel**~~ **CONSTRUÍDA (2026-07-21).** `Api.Directory.Preparations.OwnProfessionalOnly` na `:read` de `Professional` (espelha `OwnAgendaOnly`): `papel == :profissional` → filtra `id == professional_id`; `professional_id: nil` → `filter(false)` (fail-closed). Recorte flui **sem tocar o frontend** para sidebar do Dia, linhas de Semana/Mês (`counts`), lista e ficha de `/api/professionals`. **Furo da mesma classe achado e fechado na verificação:** `/api/availability` aceita `professional_id` explícito e lê fontes com `authorize?: false` (a recorte não morde) — um profissional sondaria a escala do colega pela URL; guarda `authorize_professionals/2` no controller → 404. **700 testes, 0 falhas.** | Decisão do **P1**. Recorte + IDOR de availability, com testes de fail-closed e do 404. | [`25 §8b`](25-agenda.md), [`27 (e)`](27-auditoria-bate-volta-visoes.md) |

### Performance de leitura

| # | Dívida | Medição | Correção candidata | Origem |
| --- | --- | --- | --- | --- |
| D-A | **`:in_range` varre o histórico inteiro** — `ends_at > from` não está em índice → `Filter`. | **40.000 linhas lidas para devolver 638.** Repetível por evento no tempo real (coalescido em 400 ms). | **Caminho decidido pelo P5:** como **não há duração máxima** (a duração vem dos tipos), o teto de duração está descartado → **índice GiST não-parcial** sobre o range. | [`27 (a)`](27-auditoria-bate-volta-visoes.md), [`28-tempo-real (c)`](28-auditoria-bate-volta-tempo-real.md), P5 |
| D-B | **Mês pede o mês, não a grade** — Jul 26–31 numa grade de agosto aparecem sem contagem; ausência de dado buscado é lida como "sem agendamento". | Grade 42 células vs teto de 31 dias. | 2 requisições, teto de 42 dias, ou marcar célula como não-carregada. Interage com D-A. | [`27 (b)`](27-auditoria-bate-volta-visoes.md) |
| D-C | **`:in_range` sem paginação.** | Segura pelo teto de 31 dias (~2.500 linhas); a Fatia 3 (pacotes) reusa o mesmo `read` com janelas maiores. | Paginação antes da Fatia 3. | [`27 (c)`](27-auditoria-bate-volta-visoes.md) |
| D-D | **`/api/availability`: 254 queries para 30 dias**, até **480 com 10 profissionais** (fan-out 1 req/prof + sonda duplicada + duplo `carregarDia`). | Medido. | (1) remover sonda duplicada [trivial]; (2) carregar fontes 1× para a janela → ~6 queries; (3) aceitar `professional_id` múltiplo; (4) devolver `timezone` no `/auth/me`. | [`26 §5.3 (f)`](26-auditoria-bate-volta-agenda.md) |
| D-Aud1 | **`COUNT(*)` do `countable: true` da tela de auditoria** — conta a clínica inteira em todo request (inclusive página 1) na tabela que mais cresce. | **0,45 ms → 9,7 ms** de 2k → 52k linhas (~0,2 µs/linha → ~100 ms a 500k). Tela owner·admin de baixo tráfego. | Decisão de **produto**: total estimado (`reltuples`), `countable: false` + `limit+1`, ou contar só com filtro — todos trocam o rótulo exato "X–Y de Z". Decidir a semântica antes de mexer. | [`32 §5`](32-auditoria-bate-volta-tela-auditoria.md) |
| D-Aud2 | **Filtro por autor (`user_id`) da auditoria faz Seq Scan da clínica** — sem índice cobrindo `user_id`. | **Seq Scan 50k linhas / 6 ms** (~60 ms a 500k). | A UI da v1 **não expõe** o filtro (só API/deep-link); índice `(clinic_id, user_id, version_inserted_at DESC)` adiciona custo de escrita na tabela mais escrita. Criar **quando a tela expuser** o filtro (serve filtro + ordenação de uma vez). `version_action_name` é da mesma classe, menos grave. | [`32 §5`](32-auditoria-bate-volta-tela-auditoria.md) |

### FKs sem índice (todas atenuadas por "arquivar em vez de excluir")

| # | Dívida | Nota | Origem |
| --- | --- | --- | --- |
| D-E | `created_by_id` sem índice → seq scan no `DELETE` de `users` (users **não** arquiva). | O caso que mais dói, porque `users` não tem a proteção do arquivamento. | [`26 §5.3 (h)`](26-auditoria-bate-volta-agenda.md) |
| D-F | `professional_id` sem btree próprio (o composto tem prefixo errado; o gist é parcial). | Atenuado: profissional arquiva. | [`27 (d)`](27-auditoria-bate-volta-visoes.md) |

### Tempo real e escrita

| # | Dívida | Medição | Correção candidata | Origem |
| --- | --- | --- | --- | --- |
| D-G | **Releitura por assinante** (`load_visible_appointment/2`) — R-D1, garante A7 sem reimplementar o filtro. Escala com espectadores, não com dados. | Linear e **bounded**: K=10 → 16 ms/30 queries; K=100 → 116 ms/300. Irrelevante no K real (3–10). | Redesenho do contrato do canal (`block` vs `signal` no `join`): Semana/Mês recarregam contagem e **não** precisam do bloco cheio. Fecha D-H junto. | [`28-ciclo #3`](28-auditoria-bate-volta-ciclo-de-vida.md), [`28-tempo-real (a)`](28-auditoria-bate-volta-tempo-real.md) |
| D-H | **Assinante do Mês paga a releitura e a descarta** (relê antes de ramificar por resolução). | 6 queries para um sinal de 2 campos. | Resolver junto de D-G. | [`28-tempo-real (b)`](28-auditoria-bate-volta-tempo-real.md) |
| D-I | **Cascata N+1 por participante** (`cascade_to_attendances.ex`) — transição de turma custa 3N escritas. | 19→25 queries de turma 1→3. **ADIADO.** Bounded pela capacidade da turma. | Caminho de escrita sem o `SetTenantGuc` global + teste de teto. | [`28-ciclo #1`](28-auditoria-bate-volta-ciclo-de-vida.md) |
| D-J | **Reload em transação separada** (`scheduling.ex`, `load_attendances`) — round-trip após o commit. | **ADIADO.** Bounded (1 tx). | Devolver as attendances do `after_action` e bifurcar status × reschedule. | [`28-ciclo #2`](28-auditoria-bate-volta-ciclo-de-vida.md) |
| D-K | **`load_clinic` por escrita no notifier** (fuso da clínica, 1 PK-hit/escrita). | Marginal (por escrita, não por assinante). | Cachear o fuso em `persistent_term`, invalidar no `update_clinic_info`. | [`28-tempo-real (d)`](28-auditoria-bate-volta-tempo-real.md) |
| D-L | ~~**Oban cron O(clínicas)/min**~~ **FEITO** (Frente 4), mas **não** como sugerido: "statement único com conexão privilegiada" foi **recusado** — `DELETE` global só existe para quem bypassa RLS, e um pool (ou `SECURITY DEFINER`) que enxerga todas as clínicas troca custo desprezível por furo permanente no isolamento (ADR-018). O que entrou: **uma transação por lote** (200 clínicas), só os ids lidos, e cron de **5 em 5 min** (o worker é backstop puro). Teste de contagem de `BEGIN` provado por mutação. | [`29 §5`](29-auditoria-bate-volta-fila-de-espera.md), [`35`](35-plano-execucao-backlog.md) |

### Correção e concorrência

| # | Dívida | Nota | Origem |
| --- | --- | --- | --- |
| D-M | **`mix test` não exercita RLS** — a suíte conecta como `postgres` (BYPASSRLS); bug de GUC ausente passa verde e só a tela em dev (ou prod) pega. | Correção: parte da suíte rodando como `movimento_app` para o gate do CI pegar. Mexe no sandbox do Ecto — **decisão de infra**. | [`26 §5.1 (a)`](26-auditoria-bate-volta-agenda.md), [`25 §10`](25-agenda.md) |
| D-N | **Autoridade do recorte em dois lugares** — escrita lê do `Membership` (`OwnProfessionalColumn`), leitura lê do `Api.Scope` (`OwnAgendaOnly`). | Via HTTP são consistentes → **não é vulnerabilidade hoje**; é a assimetria que vira uma se alguém mexer numa das duas. | [`26 §5.1 (b)`](26-auditoria-bate-volta-agenda.md) |
| D-O | **Locking otimista vs `require_atomic? false`** — `atomic_update(:version, …)` não coexiste com o `SetTenantGuc` (before_action). | Resolvido na E4 como guard de versão via validation no fetch-then-update + a constraint fechando a corrida. Registrado como o padrão a manter, não a reabrir. | [`25 §10`](25-agenda.md) |
| D-P | **Timezone / DST** — Brasil sem DST desde 2019, mas o tz database guarda transições e `Clinic.timezone` é coluna livre. | Fixar a política `{:gap, …}`/`{:ambiguous, …}` **uma vez** e testar com um tz que tenha DST, senão a regra fica sem cobertura real. | [`25 §10`](25-agenda.md) |
| D-Q | **`HasClinicRole`: 5 queries idênticas de `memberships` por request** — reconsulta a cada avaliação de policy. | Não cresce com linhas, cresce com nº de leituras. Memoizar por request (o `Api.Scope` já carrega `papel`). | [`26 §5.3 (g)`](26-auditoria-bate-volta-agenda.md) |
| D-R | **`pool_size: 10` vs o fan-out** — 10 profissionais saturam o pool num único render de availability. | Não medido sob carga. | [`26 §5.3 (i)`](26-auditoria-bate-volta-agenda.md) |
| D-S | **Não medido por falta de volume** — se `attendances_clinic_id_appointment_id_index` é morto ou adormecido, custo do check da exclusion por INSERT, comportamento do pool. | Semear ~1.800 linhas resolveria; **não feito para não escrever no banco de dev sem autorização.** | [`26 §5.4`](26-auditoria-bate-volta-agenda.md) |
| D-T | **`mint 1.9.1` — CVEs HIGH/MEDIUM** (memory-exhaustion / request-smuggling). | **Não é do diff da agenda** — dep transitiva pré-existente. Handoff para uma decisão de bump separada. | [`29 §5`](29-auditoria-bate-volta-fila-de-espera.md) |
| D-V | **Bloco fantasma na coluna de origem** — remarcar trocando de **profissional** não remove o bloco da tela de quem via a agenda de origem no modo `block` (Dia/Lista): a releitura por assinante devolve `nil` (o bloco já não é dele) e `nil` vira "não empurra nada". | **Novo, achado na Frente 3.** Irmão do fantasma entre dias, que o notifier já resolve emitindo nos dois tópicos. Aqui não há o que empurrar: o bloco saiu do recorte do assinante. Precisaria de um evento de **remoção** (`appointment_left`) com o id — decisão de contrato de wire. O modo `signal` (Semana/Mês) **não** tem o defeito: desde a Frente 3 o evento carrega `professional_ids` com origem e destino, e as duas agendas recebem o sinal. | Frente 3 |
| D-U | **DRY fila ↔ agenda** (`finish`/`parseIds`, `/pacientes` gêmeo, boilerplate de socket, projeção de paciente, `same_clinic/2`). | O projeto **clona por fatia de propósito**; consertar toca código já entregue. Candidato a consolidação futura, baixo valor/risco. | [`29 §5`](29-auditoria-bate-volta-fila-de-espera.md) |

---

## 5. Resíduos de segurança (baixa, registrados) 🔧

Nenhum quebra o isolamento de tenant; registrados para não sumirem.

| # | Resíduo | Estado | Origem |
| --- | --- | --- | --- |
| S1 | ~~**Revogação não alcança socket já aberto**~~ **RESOLVIDO** (Frente 3): `ApiWeb.SocketRevocation` (notifier de `Membership`) derruba os sockets do usuário em `revoke_access` **e** em mudança de papel — o escopo do canal é capturado no `join`, então rebaixar sem derrubar deixaria o recorte antigo valendo pelo resto da conexão. | [`28-tempo-real (e) R1`](28-auditoria-bate-volta-tempo-real.md), [`35`](35-plano-execucao-backlog.md) |
| S2 | **Token na query string do WS** — bearer visível em log de proxy. | Mitigado pela vida de 900 s; trade-off aceito (09 §8). | [`28-tempo-real (e) R2`](28-auditoria-bate-volta-tempo-real.md) |
| S3 | **Host de dev (`localhost:4010`) na CSP de prod** — `connect-src` de prod carrega origem de dev. | Inexplorável em prod. Fix opcional: derivar hosts por ambiente no build. | [`28-tempo-real (e) R3`](28-auditoria-bate-volta-tempo-real.md) |
| S4 | **`professional_in_clinic?/2` aceita profissional arquivado** no hold. | Inofensivo: o hold é efêmero (10 min) e a **conversão** bate no `ReferencesActive` (recusa prof inativo). O portão real é na criação do agendamento. Registrado, não corrigido. | [`29 §5`](29-auditoria-bate-volta-fila-de-espera.md) |

---

## 6. Recomendação de priorização

As cinco decisões de produto (§1) estão **fechadas**. O que sobra é execução. Ordem sugerida
quando a agenda voltar à pauta:

1. **T-P1** — recortar a lista de profissionais por papel (decisão do P1). Curto, com o cuidado de
   fail-closed; alcança as três visões + availability de uma vez.
2. **D-A + D-D** — as duas dívidas de leitura já *medidas* como caras. O caminho do D-A ficou
   fechado pelo P5 (índice GiST não-parcial); D-D tem um passo trivial (remover a sonda duplicada).
3. **F1/F2/F3** — valor de produto com backend pronto; puro custo de UI.
4. **F8 (eliminação LGPD, hard delete)** — fatia a construir; desenho fechado (apagar de verdade +
   podar a trilha), antes da primeira clínica real que peça exclusão.
5. O resto (D-B..D-U, S1..S4) é bounded e revisitável sob volume real.

> **P2/P3 encerradas:** retenção da trilha e do `obs` não serão tratadas agora, por decisão.
