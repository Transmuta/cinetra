# 69 — Pacotes: protótipo × construído (criação, listagem, ações) + plano de UI/UX

Análise completa da fatia **Pacotes** — o que o protótipo
([`interface/Movimento.dc.html`](../interface/Movimento.dc.html)) especifica, o que existe hoje no
`api/` e no `web/`, o que faltou **e o motivo**, mais o diagnóstico de UI/UX com proposta concreta
para o cartão da ficha e para o formulário de criação.

Data: 2026-07-28. Referências cruzadas: [ADR-011](00-decisoes.md), [09 §3.4/§4](09-contrato-api.md),
[42](42-bate-volta-pacotes-e-turma.md), [43](43-bate-volta-onda-3.md), [56](56-ficha-do-paciente-ui.md).

## 0. Como isto foi apurado

Leitura pareada do protótipo (linhas 318–805, 1100–1180, 1683, 1876–1896) contra o código de
produção: [`api/lib/api/packages/`](../api/lib/api/packages/),
[`api/lib/api_web/router.ex:162-182`](../api/lib/api_web/router.ex#L162-L182),
[`web/src/lib/components/patients/PackageList.svelte`](../web/src/lib/components/patients/PackageList.svelte),
[`PackageCreateModal.svelte`](../web/src/lib/components/patients/PackageCreateModal.svelte),
[`PackageBulkModal.svelte`](../web/src/lib/components/patients/PackageBulkModal.svelte).

**Não houve verificação ao vivo nesta rodada**: as duas sessões salvas do Playwright
(`owner`, `movimento-dev-ana`) expiraram e o pedido de magic link não chegou à API (0 mensagens em
`/dev/mailbox`). Todo achado abaixo é de código, não de tela rodando — o que significa que os itens
de **coerência** (§6) são fortes candidatos, mas ainda não foram provados com um teste vermelho.
Quando forem consertados, a ordem do [CLAUDE.md](../CLAUDE.md) vale: teste que falha primeiro.

## 1. Placar em uma tela

| Bloco | Protótipo | Produção | Estado |
| --- | --- | --- | --- |
| **Criar pacote** (grade + prévia + save-gate) | `modalPacote` [`:691`](../interface/Movimento.dc.html#L691) | `PackageCreateModal` + `POST /packages` | ✅ construído (e **melhor**: prévia é do servidor) |
| Falta punitiva na criação | [`:720`](../interface/Movimento.dc.html#L720) | idem | ✅ |
| Pular feriado e estender a série | `computeSerie` [`:1081`](../interface/Movimento.dc.html#L1081) | `Series.project/5` | ✅ |
| "Agendar mesmo assim" (encaixe) | [`:750`](../interface/Movimento.dc.html#L750) | `forcar` + gate | ✅ |
| **Listar pacotes** na ficha | `pacotesCard` [`:416`](../interface/Movimento.dc.html#L416) | `PackageList` | ⚠️ construído, **muito** mais pobre |
| Trilha de sessões (bolinhas) | `pkgTrail` [`:414`](../interface/Movimento.dc.html#L414) | — | ❌ |
| Código do pacote (`PIL-2605`) | `pkgCode` [`:380`](../interface/Movimento.dc.html#L380) | — | ❌ |
| Grade legível no cartão (`Seg 08:00 · Dra. Ana`) | `pkgGradeLabel` [`:333`](../interface/Movimento.dc.html#L333) | — | ❌ (dado já vai no JSON) |
| Próxima sessão no cartão | `pkgContext` [`:506`](../interface/Movimento.dc.html#L506) | — | ❌ |
| Chip "Acabando" | `pkgStatusMeta` [`:334`](../interface/Movimento.dc.html#L334) | `acabando` calculado, **não usado** | ❌ |
| Histórico recolhível (pacotes mortos) | [`:448`](../interface/Movimento.dc.html#L448) | — | ❌ |
| **Pausar / Retomar / Cancelar** | [`:553`](../interface/Movimento.dc.html#L553)–[`:575`](../interface/Movimento.dc.html#L575) | `pause`/`resume`/`cancel` | ✅ construído (e **mais correto**: retomada reprojeta p/ o futuro, GAP-06) |
| Massa (prof/horário das futuras) | `applyMassaPacote` [`:1149`](../interface/Movimento.dc.html#L1149) | `bulk_adjust` + `PackageBulkModal` | ✅ parcial (escopo sempre `todas`) |
| Massa: cancelar escopo | `cancelarMassaPacote` [`:1174`](../interface/Movimento.dc.html#L1174) | endpoint existe, **sem tela** | ⚠️ decisão registrada (doc 43 §5g) |
| Ver todas as sessões | `modalSessoes` [`:638`](../interface/Movimento.dc.html#L638) | — | ❌ |
| Ajustar grade do pacote | `modalAjustarGrade` [`:664`](../interface/Movimento.dc.html#L664) | — | ❌ (contrato 09:441 prevê `PATCH /packages/:id/grade`) |
| +/− sessões (total editável) | [`:532`](../interface/Movimento.dc.html#L532)/[`:544`](../interface/Movimento.dc.html#L544) | — | ❌ (contrato 09:444/445) |
| Arquivar no histórico (`concluido`) | `archivePkg` [`:576`](../interface/Movimento.dc.html#L576) | — | ❌ (contrato 09:446) |
| Renovar pacote | `modalRenovar` [`:606`](../interface/Movimento.dc.html#L606) | — | ✅ **descartado de propósito** (ADR-011) |
| Pacote visível na **agenda** (bloco) | [`:1683`](../interface/Movimento.dc.html#L1683) | — | ❌ |
| Seção do pacote no **drawer** | `drawerPkgSection` [`:1876`](../interface/Movimento.dc.html#L1876) | — | ❌ |

Endpoints hoje ([`router.ex:162-182`](../api/lib/api_web/router.ex#L162-L182)): `index`, `preview`,
`create`, `pause`, `resume`, `cancel`, `bulk_adjust`, `bulk_cancel`. O contrato
[`09 §4`](09-contrato-api.md) lista **quatro** que não existem: `PATCH /packages/:id/grade`,
`POST /packages/:id/sessions`, `DELETE /packages/:id/sessions/:appointment_id`,
`POST /packages/:id/archive`.

## 2. Criação — o que diverge

O motor está **acima** do protótipo: a prévia é server-side ([`Api.Packages.Preview`](../api/lib/api/packages/preview.ex)),
classifica seis estados (`ok/feriado/fora_expediente/conflito/cheia/join`), o `fora_expediente` é
bloqueio absoluto (D14) e o 422 devolve a prévia nova quando o calendário mudou entre ver e
confirmar. Isso não é dívida — é a parte bem-feita da fatia.

A divergência é de **formulário**:

| | Protótipo | Produção |
| --- | --- | --- |
| Campos | Paciente, Profissional, Tipo, Quantas, Início, Falta punitiva, Dias+horários | **Nome**, Tipo, Profissional, Total, Início, Dias+horários, **Cor**, Falta punitiva |
| Nome do pacote | não existe — o rótulo é o **tipo**, o identificador é o **código** `PIL-2605` | campo de texto, **primeiro** da tela, auto-sugerido |
| Cor | não existe — herda do **tipo** (`pkgTypeColor` [`:374`](../interface/Movimento.dc.html#L374)) | 8 amostras clicáveis |
| Agrupamento | seção "Grade fixa da semana" + prévia com resumo | nenhuma seção; três grids diferentes empilhados |
| "Igualar todos" os horários | sim [`:732`](../interface/Movimento.dc.html#L732) | ❌ |
| Resumo da série | `N sessões serão agendadas · 05/08 → 30/09` [`:739`](../interface/Movimento.dc.html#L739) | ❌ (só a lista) |
| Feriado | `⚠ N em feriado — série estendida +N` [`:743`](../interface/Movimento.dc.html#L743) | linha "Feriado — pulado" na lista, sem o "+N" |
| Conflitos | lista **separada** só dos problemas, com o motivo | misturados na lista de todas as ocorrências |
| Prévia | chips compactos (uma pílula por data) | uma **linha inteira** por sessão, até 60 |
| Início no passado | `min={hoje}` [`:719`](../interface/Movimento.dc.html#L719) | ❌ sem `min` |

Os dois campos que a produção **inventou** (`nome`, `cor`) são exatamente os dois primeiros/últimos
que o usuário vê, e ambos são decisões sem consequência que ele entenda: o protótipo nomeia e
colore o pacote pelo **tipo de atendimento**, que já tem nome, sigla, ícone, duração e cor
cadastrados em `/configuracoes/tipos`. Escolher uma cor de pacote diferente da cor do tipo produz
duas verdades para o mesmo bloco na agenda.

## 3. Listagem — o cartão da ficha

O que o cartão do protótipo mostra por pacote ([`pkgBlock:461`](../interface/Movimento.dc.html#L461)):
código, ícone+nome do tipo, duração, data de início, chip de status, **grade legível**, **trilha de
bolinhas** (uma por sessão, com estado e tooltip), contador `usadas/total` grande, "N restantes",
e o **contexto**: próxima sessão, ou o aviso "acabando/concluído", ou o painel de pausa com a data
de retomada.

O que o cartão de produção mostra
([`PackageList.svelte:93-118`](../web/src/lib/components/patients/PackageList.svelte#L93-L118)):
bolinha colorida, nome digitado, `"{restantes} de {total} restantes"`, chip de status, barra de
progresso. E três botões.

Não dá para responder, olhando o cartão: **que tipo é**, **com quem**, **em que dias e horas**,
**quando é a próxima**, **quando começou**, **quantas já foram**. É essa a origem do "não estou
entendendo" — não é estética, é ausência de resposta.

Dois detalhes de leitura que atrapalham sozinhos:

- **`"10 de 10 restantes"`** ([`:104`](../web/src/lib/components/patients/PackageList.svelte#L104))
  é ambíguo em qualquer estado: com 3 usadas lê-se "7 de 10 restantes", e o primeiro número muda de
  significado conforme o pacote anda. O protótipo usa `3/10` grande + "7 restantes" ao lado — dois
  números com papéis fixos.
- **texto e barra contam coisas diferentes**: o texto fala de *restantes*, a barra enche com
  *usadas* ([`pct:55`](../web/src/lib/components/patients/PackageList.svelte#L55)). Dois modelos
  mentais em 20px.

## 4. Ações da listagem

| Ação | Protótipo | Produção |
| --- | --- | --- |
| Onde vivem | menu `⋯` por pacote [`:509`](../interface/Movimento.dc.html#L509) | 3 botões soltos no cartão |
| Ver todas as sessões | ✅ | ❌ |
| Ajustar grade / horário | ✅ (remarca as futuras **e** grava a grade nova) | ❌ — existe só a massa, que **não** grava a grade |
| Sessões +/− | ✅ stepper no menu | ❌ |
| Pausar / Retomar | ✅ | ✅ |
| Arquivar (quando concluído) | ✅ | ❌ |
| Cancelar pacote | ✅ com modal contando as sessões liberadas | ✅ com `ConfirmDialog` (sem a contagem) |
| Escopo da massa (`esta`/`próximas`/`todas`) | ✅ 3 opções | fixo em `todas` — **decisão registrada** no cabeçalho do [`PackageBulkModal`](../web/src/lib/components/patients/PackageBulkModal.svelte#L5-L12) |

A massa de produção é **mais correta** que a do protótipo num ponto que vale registrar: o alvo é a
**presença**, não o bloco — numa turma, mexer no pacote da Maria não arrasta João e Ana. O
protótipo arrastava (`pkgOf`), e o mesmo furo foi fechado no `cancel`/`resume` na Onda 3 (doc 43 §5c).

## 5. O que faltou — e por quê

Três categorias distintas. Misturá-las é o que faz a fatia parecer mais incompleta (ou mais
completa) do que é.

### (a) Descartado de propósito — não é dívida

| Item | Motivo |
| --- | --- |
| **Renovar pacote** (modal, sucessor, status `:renovado`) | [ADR-011](00-decisoes.md): o fluxo de renovar do protótipo **já adicionava sessões ao mesmo pacote**; o ramo de "pacote-sucessor" era código morto (nenhuma UI setava `renovadoDe`). Decisão: não há renovação, o `total` é editável. |
| **Escopo `esta`/`próximas` na massa da ficha** | precisa de uma sessão de **referência**, que só existe olhando a agenda. Registrado no componente. |
| **`bulkCancelPackage` no BFF** | doc 43 §5g: ponta parada (endpoint exposto sem tela nem teste). Removido com o motivo no lugar. |
| **Validade do pacote** | ADR-013/D6. |

### (b) Planejado, com contrato escrito, e não construído

| Item | Contrato | Motivo aparente |
| --- | --- | --- |
| `PATCH /packages/:id/grade` (ajustar grade) | [09:441](09-contrato-api.md) | O moduledoc do recurso ([`package.ex:31-36`](../api/lib/api/packages/package.ex#L31-L36)) diz que a fatia nasce com `create`/`read` e que "as ações de ciclo de vida (`:pause`/`:resume`/`:cancel`/`:adjust_grade`/…) entram com elas". Vieram três das quatro. O `PackageSchedule` **já tem** `update` com policy ([`package_schedule.ex:48-56`](../api/lib/api/packages/package_schedule.ex#L48-L56)) — falta a code interface no domínio, o wrapper que remarca as futuras, o controller e a tela. |
| `POST /packages/:id/sessions` (+1) | [09:444](09-contrato-api.md) | idem. É o lado "aumentar" do ADR-011. |
| `DELETE …/sessions/:id` (−1) | [09:445](09-contrato-api.md) | idem. É o lado "diminuir" — a razão declarada do ADR-011. |
| `POST /packages/:id/archive` | [09:446](09-contrato-api.md) | idem. |
| Trilha / "ver todas as sessões" | — | UI pura; ninguém a pediu de novo depois da Fatia 5. |
| Pacote na agenda (bloco + drawer) | — | a Onda 3 (turma/A2) reescreveu o drawer por presença e não trouxe a seção de pacote junto. |

**O motivo comum, e ele é um só:** o capítulo do ciclo de vida do pacote foi aberto na Fatia 5
(doc 09, criação + pausar/retomar/cancelar) e **nunca reaberto**. A Onda 3 entrou por cima com
turma/presença e consumiu o assunto; o próprio bate-volta da época
([42, item A-6](42-bate-volta-pacotes-e-turma.md)) adiou uma corrida conhecida "para a etapa que
reabrir o ciclo de vida do pacote" — etapa que não aconteceu. As ondas 4, 5 e 6 foram
notificações, produção e limpeza.

### (c) Consequência prática de (b)

O que a recepção **não consegue fazer hoje**, e que a clínica faz toda semana:

1. **Estender um pacote que acabou.** Sem `+1` e sem renovação, o único caminho é criar um pacote
   novo — que nasce com contador zerado e vira um segundo cartão na ficha. O ADR-011 tirou o
   "renovar" **em troca** do total editável; o troco não foi pago.
2. **Mudar o dia da semana da série.** A massa muda profissional e horário, nunca o **dia**
   (`dows`). Trocar "terça e quinta" por "segunda e quarta" exige cancelar o pacote e refazer.
3. **Tirar uma sessão a mais** (paciente viajou 15 dias): não há `−1`; ou se cancela sessão a
   sessão pela agenda — e aí o `total` fica mentindo — ou se cancela o pacote inteiro.
4. **Ver a série do pacote.** A ficha mostra as próximas 5 sessões do *paciente* (doc 56), com uma
   tag genérica "pacote" ([`PatientUpcoming.svelte:60`](../web/src/lib/components/patients/PatientUpcoming.svelte#L60)) —
   com dois pacotes ativos não dá para saber qual é qual.

## 6. Achados de coerência (candidatos a bug — não provados ao vivo)

Estes seis não são "faltou tela": são coisas construídas que se contradizem. Cada um vira um teste
vermelho antes do conserto.

1. **`:concluido` nunca é setado.** O enum tem o valor
   ([`package_status.ex:14`](../api/lib/api/packages/package_status.ex#L14)), o `statusLabel` do web
   sabe desenhá-lo, e **nenhum código o atribui** — não há `archive`, e nada observa `restantes == 0`.
   Efeito: um pacote de 10/10 fica **"Ativo"** para sempre, no topo da ficha, ao lado do pacote que
   está de fato correndo. É o principal motor da bagunça visual do cartão.
2. **A massa não atualiza a grade.** `bulk_adjust` reescreve as sessões futuras, mas não toca
   `PackageSchedule` (nenhuma menção a `schedule` em [`bulk.ex`](../api/lib/api/packages/bulk.ex)).
   Depois de mover o pacote para outro profissional/horário, a grade guardada é a antiga — e é
   **ela** que o `Materializer` usa ([`materializer.ex:94`](../api/lib/api/packages/materializer.ex#L94))
   quando o `resume_package` reprojeta as seguradas. Pausar + retomar depois de uma massa devolve
   as sessões no horário **velho**.
3. **O cabeçalho conta pacotes mortos.** `packages.length`
   ([`PackageList.svelte:73`](../web/src/lib/components/patients/PackageList.svelte#L73)) inclui
   cancelados e (quando existirem) concluídos; o protótipo conta `· N ativos`. Um paciente de dois
   anos verá "Pacotes · 7".
4. **`acabando` é calculado e jogado fora.** O agregado existe
   ([`package.ex:218`](../api/lib/api/packages/package.ex#L218)), viaja no JSON, e o chip do web só
   conhece quatro status — o aviso "faltam 2 sessões", que é o gatilho comercial da renovação, não
   aparece em lugar nenhum.
5. **Início no passado.** O campo não tem `min`
   ([`PackageCreateModal.svelte:294`](../web/src/lib/components/patients/PackageCreateModal.svelte#L294)),
   o protótipo tem. Nada no `Series`/`Appointment` recusa data passada, então dá para materializar
   uma série inteira atrás de hoje, que nasce `:agendado` e nunca se resolve.
6. **CTA que desabilita sem dizer por quê.** `podeSalvar` exige `completo`
   ([`:86-95`](../web/src/lib/components/patients/PackageCreateModal.svelte#L86-L95)); se faltar um
   horário de dia, ou se o total passar de 60, o botão apaga e **nenhuma** mensagem aparece — a
   prévia continua no texto "Preencha o tipo, o profissional e ao menos um dia", que pode já estar
   satisfeito.

## 7. UI/UX — o cartão da lista

Princípio: o cartão responde, o menu executa. Hoje é o contrário — o cartão executa (três botões) e
não responde nada.

```
┌───────────────────────────────────────────────────────────────┐
│ ▪ Pacotes · 2 ativos                          [+ Novo pacote] │
├───────────────────────────────────────────────────────────────┤
│ ▪ PIL-2607   Pilates Solo · 50min · início 07/07     [Ativo] ⋯│
│   🗓 Seg 08:00, Qua 08:00 · Dra. Ana Prado                     │
│   ●●●●●○○○○○  ← trilha: 5 feitas, 1 falta, 4 agendadas         │
│   5/10  5 restantes                                           │
│   🕐 Próxima: Qua 30/07 · 08:00                                │
├───────────────────────────────────────────────────────────────┤
│ ▪ RPG-2606   RPG · 60min · início 12/06          [Acabando] ⋯ │
│   ⚠ Faltam 2 sessões para concluir.                           │
├───────────────────────────────────────────────────────────────┤
│ ▾ Histórico (3)                                               │
└───────────────────────────────────────────────────────────────┘
```

Ordenado por custo de implementação:

| # | Mudança | Custo | Por quê |
| --- | --- | --- | --- |
| 1 | Chip **Acabando** quando `acabando` | trivial | dado já chega; é o gatilho de renovação |
| 2 | `5/10` + "5 restantes" no lugar de "X de Y restantes" | trivial | tira a ambiguidade e casa com a barra |
| 3 | Contar **ativos** no cabeçalho | trivial | — |
| 4 | **Grade legível** (`Seg 08:00, Qua 08:00 · Dra. Ana`) | baixo (front) | `grade.dows/horarios/professional_id` já vêm no JSON e a ficha já tem `data.professionals` |
| 5 | **Próxima sessão** por pacote | baixo | derivável de `data.upcoming` (tem `package_id`); melhor ainda com um `proxima_em` no JSON, porque `upcoming` para em 5 |
| 6 | Ações no menu `⋯`; cartão só informa | baixo | 3 botões × N pacotes é o ruído dominante |
| 7 | Seção **Histórico** recolhível (cancelado/concluído) | baixo | tira os mortos do caminho |
| 8 | Tipo + duração no cartão | baixo + **backend** | falta `appointment_type_id`/nome no [`PackagesJSON.package/1`](../api/lib/api_web/packages_json.ex) |
| 9 | **Trilha** de bolinhas + "ver todas as sessões" | médio | precisa de `GET /packages/:id/sessions`; é o que torna o pacote auditável na ficha |
| 10 | Código `PIL-2607` | médio | depende da sigla do tipo; substitui o campo "nome" (§8) |

## 8. O formulário de criação — diagnóstico e proposta

### 8.1 Por que está bagunçado (causas, não sintomas)

1. **Três sistemas de grade empilhados.** `md:grid-cols-2` com quatro filhos, onde o quarto é
   *outro* `grid-cols-2` ([`:246-296`](../web/src/lib/components/patients/PackageCreateModal.svelte#L246-L296)):
   a segunda linha põe "Profissional" (½) ao lado de "Total"+"Início" (¼ cada). Quatro larguras de
   campo diferentes na mesma tela, sem hierarquia que as justifique. Mais abaixo, um terceiro grid
   pareia **Cor** com **Falta punitiva**.
2. **Nenhuma seção.** O protótipo separa "dados" de "**Grade fixa da semana**" de "prévia". Aqui é
   um fluxo contínuo de 8 controles onde o campo mais consequente (falta punitiva) tem o mesmo peso
   visual do menos consequente (cor).
3. **Uma decisão irreversível disfarçada de checkbox.** `falta_punitiva` é `allow_nil? false` e
   **imutável** — não há ação de update que a aceite. É a regra comercial combinada com o paciente,
   e a tela a apresenta como um checkbox ao lado da paleta de cores, sem dizer que não dá para
   mudar depois.
4. **Dois campos inventados na frente dos essenciais.** "Nome do pacote" abre a tela; "Cor" ocupa
   metade de uma linha. Nenhum dos dois existe no protótipo (§2) — o pacote **é** o tipo de
   atendimento.
5. **A prévia é uma lista, não um resumo.** Até 60 linhas de largura total, cada uma repetindo o
   mesmo horário, num scroll de 208px. A informação que decide ("são 10 sessões, de 05/08 a 30/09,
   2 batem em conflito") não está escrita em lugar nenhum — precisa ser reconstruída lendo o wall.
6. **O botão morre calado** (§6.6) e o erro de salvamento aparece **abaixo** da prévia, fora da
   vista, num modal que já está rolando.

### 8.2 Proposta

```
┌─ Novo pacote ─────────────────────────────── Mariana Alves ──┐
│                                                              │
│ 1 · O QUE                                                    │
│ ┌────────────────────────────┬─────────────────────────────┐ │
│ │ Tipo de atendimento     ▾  │ Profissional             ▾  │ │
│ │ Pilates Solo · 50min       │ Dra. Ana Prado              │ │
│ └────────────────────────────┴─────────────────────────────┘ │
│ ┌────────────────────────────┬─────────────────────────────┐ │
│ │ Sessões    [ − ]  10  [ + ]│ Começa em    28/07/2026     │ │
│ └────────────────────────────┴─────────────────────────────┘ │
│                                                              │
│ 2 · QUANDO  (grade fixa da semana)                           │
│  D  [S] T  [Q] Q  S  S                    · Igualar horários │
│  Seg  08:00     Qua  08:00                                   │
│                                                              │
│ 3 · REGRA DA FALTA                        ⚠ não muda depois  │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ ◉ Falta desconta uma sessão   ○ Falta não desconta       │ │
│ │ Falta não justificada consome 1 das 10 sessões.          │ │
│ └──────────────────────────────────────────────────────────┘ │
│                                                              │
│ ── Prévia ─────────────────────────────────────────────────  │
│ 10 sessões · 05/08 → 30/09 · 1 feriado pulado (série +1)     │
│ [05/08][07/08][12/08][14/08][19/08]…      ← chips compactos  │
│                                                              │
│ ⚠ 2 horários com conflito                                    │
│   19/08 Ter 08:00 — choca com Avaliação · João Prado         │
│   26/08 Ter 08:00 — choca com Pilates · turma cheia (4/4)    │
│   ☐ Agendar mesmo assim (encaixe) nesses horários            │
│                                                              │
│                              [ Cancelar ]  [ Criar pacote ]  │
└──────────────────────────────────────────────────────────────┘
```

Mudanças, em ordem de impacto sobre "não estou entendendo":

| # | Mudança | Custo |
| --- | --- | --- |
| 1 | **Três seções numeradas** (o quê / quando / regra da falta) + prévia. Uma grade só, de 2 colunas iguais. | baixo |
| 2 | **Resumo da série em uma frase** acima dos chips: `N sessões · dd/mm → dd/mm · N feriado pulado`. É a leitura que decide. | baixo |
| 3 | **Chips no lugar de linhas** na prévia (uma pílula por data, tom por issue) + **lista separada só dos problemas**, com o motivo. Igual ao protótipo [`:741-750`](../interface/Movimento.dc.html#L741-L750). | médio |
| 4 | **Some com "Nome"** — derive do tipo (`Pilates Solo 10`) e mostre como texto; se for preciso editar, um lápis discreto. **Some com "Cor"** — herde a cor do tipo. Dois campos a menos, zero perda. | baixo |
| 5 | **Falta punitiva vira escolha explícita** (dois rádios ou switch com card), em seção própria, com o selo "não muda depois" e a frase concreta ("consome 1 das 10"). | baixo |
| 6 | **Total com stepper** −/+ (o protótipo usa stepper em toda parte) e `min`/`max` visíveis; digitar acima de 60 mostra a razão em vez de apagar o botão. | baixo |
| 7 | **`min={hoje}` no início** (§6.5). | trivial |
| 8 | **Dizer por que o botão está desabilitado**: uma linha ao lado do CTA ("falta o horário de Qua"), em vez do silêncio. | baixo |
| 9 | **Erro de salvamento no rodapé fixo**, junto do botão, não no fim do scroll. | baixo |
| 10 | **"Igualar horários"** quando há 2+ dias ([`:732`](../interface/Movimento.dc.html#L732)). | trivial |

## 9. Ordem sugerida

1. **Coerência primeiro** (§6) — cada um com teste vermelho antes: `:concluido`
   (via `archive` **ou** derivado de `restantes == 0`), grade × massa, contagem do cabeçalho,
   `min` da data. São os que fazem a tela mentir.
2. **Cartão legível** (§7 itens 1–7) — só front, sem backend, e é o que responde "não estou
   entendendo".
3. **Formulário** (§8 itens 1–10) — idem, só front, salvo o resumo de feriado (já vem na prévia).
4. **Reabrir o ciclo de vida** (§5b): `adjust_grade`, `+1/−1`, `archive`, `GET sessions`. É onde
   moram as quatro operações que a recepção não consegue fazer hoje, e é a etapa em que a corrida
   A-6 do doc 42 tem de ser resolvida junto.
5. **Pacote na agenda** (bloco + seção do drawer) — reencaixar no drawer por presença da Onda 3.

## 10. Plano detalhado

Cinco blocos, 27 itens. Cada item traz **onde**, **como**, **o teste vermelho que vem primeiro**
(regra do [CLAUDE.md](../CLAUDE.md)), o **cuidado** que já se conhece, e o tamanho (P ≈ minutos·1h,
M ≈ 1–3h, G ≈ meio dia+). Os blocos B1→B3 são independentes entre si; B4 depende das decisões D1–D4
abaixo; B5 depende de B4 só para o contador.

### Decisões — RESOLVIDAS (2026-07-28)

| | Pergunta | **Decisão** |
| --- | --- | --- |
| **D1** | "Concluído" é **derivado** (`restantes == 0`), **ação manual** (`archive`) ou os dois? | **Ação manual.** O `status` só vira `:concluido` quando alguém arquiva — nada no sistema fecha o pacote sozinho. Sem calculation `concluido?` no domínio. |
| **D2** | O `bulk_adjust` (massa) deve **reescrever a grade** do pacote? | **Sim**, quando o escopo é `todas`. Com escopo `esta`/`proximas`, não toca a grade. Fecha o achado §6.2. |
| **D3** | O `−1` remove **qual** sessão? | **A última não consumida — e nunca uma sessão cuja data já passou.** Só alcança futuro (a data de hoje em diante, pelo fuso da clínica) e só o que não consumiu. |
| **D4** | O `+1` **reativa** um pacote concluído/cancelado? | **Concluído sim; cancelado não.** |

**O que a D1 muda no plano.** O chip "Concluído" só aparece depois do arquivamento, então um pacote
10/10 fica **"Ativo" com 0 restantes** até alguém agir — e é a tela que precisa deixar isso legível.
Duas consequências, ambas fiéis ao protótipo (que também não fecha o pacote sozinho — o `pkgDone`
[`:329`](../interface/Movimento.dc.html#L329) é leitura de tela, não estado):

- o chip **"Acabando"** (B1.4) passa a ser o aviso que sobra, e vale mais;
- o botão **"Arquivar no histórico"** aparece no menu quando `restantes == 0` — cálculo **de tela**
  sobre um dado que já chega no JSON, como o protótipo faz em [`:526`](../interface/Movimento.dc.html#L526).

### B1 — Coerência (os que fazem a tela mentir)

**B1.1 — `archive`: o único caminho até `:concluido`** · M (**D1**)
- *Onde*: [`package.ex`](../api/lib/api/packages/package.ex), [`packages.ex`](../api/lib/api/packages.ex), controller, `router`, BFF, menu do cartão.
- *Como*: ação `mark_completed` no molde dos três `mark_*` que já existem + wrapper + `POST /packages/:id/archive` (contrato [09:446](09-contrato-api.md)). O botão só aparece com `restantes == 0` (regra **de tela**, [`:526`](../interface/Movimento.dc.html#L526)).
- *Teste vermelho*: arquivar um pacote 10/10 → hoje não há rota; depois, `status == :concluido`, ele sai da contagem de ativos (B1.3) e cai no histórico (B2.6).
- *Cuidado*: por **D1**, nada de gatilho automático — a transição de presença roda em lote/rollup (Onda 3), e escrever no pacote de dentro dali reabre a corrida A-6 do [doc 42](42-bate-volta-pacotes-e-turma.md). Arquivar um pacote com sessão **futura** ainda agendada precisa de decisão: recomendo recusar (422 "cancele ou conclua as sessões restantes"), senão sobra sessão viva num pacote fechado.
- *Nota*: este item **é** o antigo B4.4 — subiu para B1 porque, com D1, o chip "Concluído" depende só dele.

**B1.2 — a massa não atualiza a grade** · M (depende de **D2**)
- *Onde*: [`bulk.ex`](../api/lib/api/packages/bulk.ex) (`adjust/3`), `PackageSchedule` já tem `update` com policy — falta a code interface no domínio.
- *Como*: com escopo `:todas` e `aplicar_profissional`/`aplicar_horario`, gravar `professional_id`/`horarios` na grade **na mesma transação** da massa.
- *Teste vermelho*: massa move o pacote para 10:00 → `pause` → `resume`; hoje as sessões voltam às 08:00 (grade velha, [`materializer.ex:94`](../api/lib/api/packages/materializer.ex#L94)).
- *Cuidado*: `horarios` é mapa `dow => "HH:MM"` com **chaves string**; escrever `%{1 => "10:00"}` quebra o `Series` no próximo uso.

**B1.3 — cabeçalho conta pacotes mortos** · P
- *Onde*: [`PackageList.svelte:73`](../web/src/lib/components/patients/PackageList.svelte#L73).
- *Como*: contar `ativo`+`pausado` ("· 2 ativos"), como [`:426`](../interface/Movimento.dc.html#L426).
- *Teste vermelho*: ficha com 1 ativo + 2 cancelados renderiza "· 3".

**B1.4 — `acabando` calculado e jogado fora** · P
- *Onde*: `chip()` em [`PackageList.svelte:48`](../web/src/lib/components/patients/PackageList.svelte#L48).
- *Como*: quinto tom, precedendo `ativo`: `acabando` → warning "Acabando".
- *Teste vermelho*: pacote com `acabando: true` renderiza "Ativo".

**B1.5 — início no passado** · P
- *Onde*: [`PackageCreateModal.svelte:294`](../web/src/lib/components/patients/PackageCreateModal.svelte#L294).
- *Como*: `min={today}` (o `Field` já repassa `min`; hoje o tipo é `number` — ampliar para `string`).
- *Teste vermelho*: data de ontem → o modal deixa criar e a série materializa no passado.
- *Cuidado*: é guarda de **tela**. Se quisermos garantia de servidor, é validação no `create_series`, não no `Appointment` (agendar no passado é legítimo no avulso).

**B1.6 — CTA que desabilita calado** · P
- *Onde*: `podeSalvar`/`completo` em [`PackageCreateModal.svelte:86-95`](../web/src/lib/components/patients/PackageCreateModal.svelte#L86-L95).
- *Como*: derivar `motivoBloqueio` ("falta o horário de Qua", "o total passa de 60") e mostrar ao lado do botão.
- *Teste vermelho*: marca Qua sem horário → botão apagado, nenhuma mensagem.

### B2 — Cartão da ficha (o "não estou entendendo")

**B2.1 — contador `5/10` + "5 restantes"** · P — troca o ambíguo "X de Y restantes" ([`:104`](../web/src/lib/components/patients/PackageList.svelte#L104)); barra e texto passam a contar a mesma coisa.
**B2.2 — grade legível** · P — `Seg 08:00, Qua 08:00 · Dra. Ana` a partir de `grade` + `data.professionals` (dado já no JSON). Porta de [`pkgGradeLabel:333`](../interface/Movimento.dc.html#L333).
**B2.3 — próxima sessão** · M — derivar de `data.upcoming` por `package_id`; **cuidado**: `upcoming` para em 5 (doc 56), então pacote com muitas futuras pode não ter a sua ali → o certo é `proxima_em` no JSON do pacote.
**B2.4 — tipo + duração + início no cartão** · M — exige `appointment_type` (nome/duração/sigla/cor) no [`PackagesJSON.package/1`](../api/lib/api_web/packages_json.ex), que hoje não manda nem o id.
**B2.5 — ações no menu `⋯`** · M — cartão informa, menu executa ([`pkgMenuPop:509`](../interface/Movimento.dc.html#L509)). Some a fileira de 3 botões por pacote.
**B2.6 — seção "Histórico" recolhível** · M — cancelados/concluídos saem da lista principal ([`:448`](../interface/Movimento.dc.html#L448)). Depende de B1.1 para saber quem é histórico.
**B2.7 — contexto por estado** · M — pausado (com "retoma em"), acabando, concluído, ou "Próxima: …" ([`pkgContext:488`](../interface/Movimento.dc.html#L488)).
**B2.8 — cancelar dizendo quantas libera** · P — o `ConfirmDialog` hoje não conta; o protótipo diz "as N sessões futuras serão liberadas" ([`:686`](../interface/Movimento.dc.html#L686)). `restantes` já está à mão.

### B3 — Formulário de criação

**B3.1 — três seções numeradas + uma grade só** · M — o quê / quando / regra da falta (§8.2). Elimina os três grids empilhados.
**B3.2 — resumo da série em uma frase** · P — `10 sessões · 05/08 → 30/09 · 1 feriado pulado (série +1)`, das `ocorrencias` que já chegam.
**B3.3 — prévia em chips + lista só dos problemas** · M — pílula por data com tom por issue; os bloqueios ganham lista própria com motivo ([`:741-750`](../interface/Movimento.dc.html#L741-L750)).
**B3.4 — sai "Nome", sai "Cor"** · M — derivar do tipo (`Pilates Solo 10` e `tipo.cor`) e enviar derivado; sem migração (as colunas continuam `allow_nil? false`). Nome editável só atrás de um lápis.
**B3.5 — falta punitiva em seção própria** · P — escolha explícita + selo **"não muda depois"** (é imutável: nenhuma ação de update a aceita) + frase concreta ("consome 1 das 10").
**B3.6 — total com stepper −/+** · P — e recusar acima de 60 **com motivo**, em vez de apagar o botão (casa com B1.6).
**B3.7 — "Igualar horários"** · P — quando há 2+ dias ([`:732`](../interface/Movimento.dc.html#L732)).
**B3.8 — erro de salvamento no rodapé fixo** · P — hoje nasce no fim do scroll, fora da vista.

### B4 — Reabrir o ciclo de vida (o troco do ADR-011)

O reuso já existe e é o que torna este bloco barato: o `Materializer` aceita `from`/`count`
([`:64-70`](../api/lib/api/packages/materializer.ex#L64-L70)), o `Bulk.cancelar_sessao/2` e o
`Bulk.alvos/3` são públicos, e o dedupe de idempotência **ignora canceladas**
([`:139-149`](../api/lib/api/packages/materializer.ex#L139-L149)) — então "cancelar e
re-materializar" é seguro mesmo caindo no mesmo instante. É a mesma forma que o `resume_package` já
usa.

**B4.1 — `+1` sessão** · M (decisões **D4**)
- *Onde*: `add_session` no recurso (aceita `total`), wrapper em `Api.Packages`, `POST /packages/:id/sessions`, BFF, stepper no menu (B2.5).
- *Como*: `total + 1` **e** `Materializer` com `from` = dia seguinte à última sessão do pacote, `count: 1`. Por **D4**: `:concluido` volta a `:ativo`; `:cancelado` **recusa** (422).
- *Teste vermelho*: **(a)** `+1` num pacote 10/10 arquivado → `total == 11`, uma sessão nova na próxima data da grade, status volta a `:ativo`; **(b)** `+1` num pacote **cancelado** → 422, nada materializado (e o guard de `:cancelado` do [`build_plan`](../api/lib/api/packages/materializer.ex#L80) segura mesmo se o job escapar).
- *Cuidado*: a materialização é **assíncrona** — a ficha precisa recarregar, ou o usuário clica `+` e não vê nada mudar. Ou se mostra "agendando…", ou este caminho é síncrono (é 1 sessão). Todo `Oban.insert` novo daqui vai com `Materializer.new(Api.Correlacao.opts())` — a correlação de log (doc 62) já entrou no `enqueue_reproject`.

**B4.2 — `−1` sessão** · M (decisão **D3**)
- *Como*: acha a **última não consumida com data ≥ hoje** (`Bulk.alvos` com escopo `:todas` já resolve "futuras não resolvidas" pelo fuso da clínica), cancela com `Bulk.cancelar_sessao/2`, `total - 1` — nunca abaixo de `usadas`.
- *Teste vermelho*: **(a)** `−1` com 8 usadas e total 10 → total 9 e a última futura cancelada; **(b)** pacote cujas sessões por resolver são todas **passadas** (3 `:agendado` da semana passada) → recusa com 422, **não** cancela a de trás; **(c)** `−1` até bater em `usadas` recusa.
- *Cuidado*: o (b) é o coração da **D3** e é o teste fácil de esquecer — "última não consumida" e "última **futura** não consumida" só divergem quando a agenda tem sessão velha por resolver, que é justamente o estado sujo de uma clínica real. Numa **turma**, cancelar é por presença, não por bloco (é o que `cancelar_sessao` já garante).

**B4.3 — `adjust_grade`** · G
- *Como*: `PATCH /packages/:id/grade` → grava a grade nova + cancela as futuras não resolvidas + `Materializer` com `from` = hoje, `count` = quantas foram canceladas. **É a forma do `resume_package`** ([`packages.ex`](../api/lib/api/packages.ex)); reusar, não reescrever.
- *Teste vermelho*: trocar Ter/Qui por Seg/Qua → hoje não há rota; depois, as futuras saem das terças e nascem nas segundas, e `usadas` não muda.
- *Cuidado*: sessão **segurada** (pausado) — o `resume` já reprojeta; decidir se `adjust_grade` num pacote pausado é recusado (recomendo recusar: 422 "retome antes de ajustar").

**B4.4 — `archive`** — **subiu para B1.1** (D1: é o único caminho até `:concluido`).

**B4.5 — `GET /packages/:id/sessions` + trilha** · G
- *Como*: lista `{data, hora, estado}` por presença (`list_package_attendances` já existe, com `include_held`), estados do protótipo: concluída/próxima/agendada/segurada/falta/feriado ([`pkgSessions:386`](../interface/Movimento.dc.html#L386)). Front: bolinhas no cartão + modal "Sessões do pacote" ([`:638`](../interface/Movimento.dc.html#L638)).
- *Teste vermelho*: pacote com 1 concluída, 1 falta e 3 futuras → a rota não existe; depois, 5 itens com os estados certos e a **próxima** marcada.

**B4.6 — corrida A-6 (pausar antes de materializar)** · G
- Dívida conhecida e **estrutural** ([doc 42](42-bate-volta-pacotes-e-turma.md)): pausar dentro da janela do job deixa pacote `:pausado` com sessões `:agendado` soltas. É esta a etapa que o doc 42 disse que a resolveria ("a etapa que reabrir o ciclo de vida"). Caminho recomendado: o `Materializer` lê o status e **materializa já segurando** quando `:pausado` (simétrico ao guard de `:cancelado` que já existe em `build_plan`).
- *Teste vermelho*: criar → pausar antes do job → rodar o job: hoje nascem sessões visíveis na agenda de um pacote pausado.

**B4.7 — código do pacote (`PIL-2607`)** · M — `sigla do tipo + AAMM` ([`pkgCode:380`](../interface/Movimento.dc.html#L380)); depende de B2.4 (tipo no JSON) e substitui o "nome" como identidade (B3.4).

### B5 — Pacote na agenda

**B5.1 — marca no bloco** · M — a sessão de pacote se identifica no bloco ([`:1683`](../interface/Movimento.dc.html#L1683)). O `package_id` **já viaja** no payload da agenda ([`agenda.ts:77`](../web/src/lib/agenda.ts#L77)) e não é usado.
**B5.2 — seção do pacote no drawer** · G — "Sessão de pacote · 3/10 · N restantes", se **esta falta debitou** o pacote, e o atalho para ajustar a grade ([`drawerPkgSection:1876`](../interface/Movimento.dc.html#L1876)). Depende de B4.3 (atalho) e de um contador por sessão.
**B5.3 — massa com escopo a partir da agenda** · M — `esta`/`próximas`/`todas` só fazem sentido com uma sessão de referência ([`modalPacoteMassa:758`](../interface/Movimento.dc.html#L758)); o `bulk_adjust` **já aceita** `escopo` + `appointment_id`, é só a tela.

### Resumo por tamanho

| Bloco | Itens | P | M | G | Depende de |
| --- | --- | --- | --- | --- | --- |
| B1 Coerência | 6 | 4 | 2 | — | D2 (só B1.2) |
| B2 Cartão | 8 | 3 | 5 | — | B1.1 (B2.6) |
| B3 Formulário | 8 | 5 | 3 | — | — |
| B4 Ciclo de vida | 7 | 1 | 3 | 3 | D1–D4 |
| B5 Agenda | 3 | — | 2 | 1 | B4.3 |

Caminho mais curto até "dá para entender": **B1 + B2 + B3** (22 itens, quase tudo P/M, nada de
migração). Caminho até "a recepção consegue operar": **B4**.

## 11. Execução (2026-07-28/29)

**B1, B2, B3 e B4 construídos.** B5 já existia — ver abaixo. Suítes: **1583 testes de backend** e
**1972 do web** verdes; `svelte-check` limpo (0 erros / 0 avisos); gate de cobertura do web passa.

### O que entrou, por bloco

| Bloco | Entregue |
| --- | --- |
| **B1** | `archive` (ação `mark_completed` + `POST /packages/:id/archive` + BFF + botão no menu); massa reescreve a grade quando o escopo é `todas`; cabeçalho conta só ativos; chip **Acabando** e **Completo**; `min` de hoje no início; motivo do CTA desabilitado |
| **B2** | Cartão reescrito: **código** `PIL-2607`, tipo + duração + início, **grade legível**, `3/10` + "7 restantes", **próxima sessão**, contexto por estado (pausado com Retomar em destaque / completo / acabando), ações no menu `⋯`, **histórico recolhível**, cancelar dizendo quantas libera |
| **B3** | Formulário em **três seções numeradas**, resumo da série em uma frase (com feriado pulado), prévia em **chips** + lista só dos problemas, **saíram** "Nome" e "Cor" (derivados do tipo), falta punitiva em seção própria com o selo *não muda depois*, stepper no total, "igualar horários", erro e motivo no rodapé fixo |
| **B4** | `+1`/`−1` (ADR-011), `PATCH /grade`, `GET /sessions` + **modal da trilha**, guard da corrida **A-6**, código do pacote |
| **B5** | **Já estava pronto** — ver §11.3 |

### 11.1 Decisões que a construção obrigou a tomar

- **`DELETE /packages/:id/sessions` sem `:appointment_id`** (desvio do contrato 09:445). Por D3,
  quem escolhe é o servidor; deixar o cliente apontar abriria a porta para apagar sessão passada.
- **`adjust_grade` recusa em pacote pausado** (422). As seguradas já são reprojetadas pela retomada;
  ajustar por baixo produziria duas reprojeções brigando pelo mesmo slot.
- **`archive` recusa com sessão futura de pé** (422). Era a pergunta em aberto do B1.1; sem o guard
  sobra sessão viva num pacote fechado.
- **A corrida A-6** (doc 42) foi resolvida **materializando e segurando**: o job lê o status e, se o
  pacote foi pausado dentro da janela, nasce com `pkg_hold` — pela regra por-presença (numa turma,
  segura a presença, não o bloco). Pular a materialização quebraria a retomada, que reprojeta pelo
  número de seguradas.

### 11.2 Efeitos colaterais consertados no caminho

- **Contrato da trilha de auditoria.** `mark_completed` e `set_total` são ações novas do `Package`,
  e o `acoes_auditadas_test` cobra as três pontas: a lista no backend, os `ACTION_LABELS`/`HEADLINES`
  em `web/src/lib/audit.ts` e o espelho em `audit.test.ts`. As três foram atualizadas.
- **Teto de queries da massa: 70 → 78.** A sincronização da grade (D2) custa ~7 queries **por massa**
  (ler a grade, a transação com a GUC, o UPDATE) — constante, não por sessão. A leitura é do
  `package_schedules`, e não do pacote com `load: [:schedule]`, justamente para manter intacta a
  asserção `packages ≤ 2`, que é a que pega custo por sessão. Aumento de teto é decisão explícita:
  está registrado aqui e no comentário do teste.
- **Um teste de RLS que apodrecia com o relógio.** `rls_smoke_test` ancorava a série em
  `2026-07-20`; a partir de 28/07 as duas sessões viraram passado e a massa achava zero — falha que
  nada tinha a ver com RLS. A âncora passou a ser a **próxima segunda depois de hoje**, e a
  asserção do espelho `session_starts_at` passou a olhar passado **e** futuro.

### 11.3 B5 não foi construído aqui — já existia

Ao rodar a suíte, a pasta `web/src/lib/components/agenda/` apareceu com trabalho **concorrente** de
outra frente, e ele **já entrega o B5.1 e o B5.2**, num desenho melhor que o planejado aqui: o selo
de pacote no bloco (`packageBadge`) e a seção do pacote no drawer **dentro do participante** — por
presença (D11), não por bloco —, com link para `/pacientes/:id#pacotes`. É de lá que veio a âncora
`id="pacotes"` na seção da ficha.

Fica **um** item aberto do plano: **B5.3 — a massa com escopo `esta`/`próximas`/`todas` a partir da
agenda**. Não foi construído para não colidir com aquela frente (o alvo é o mesmo drawer, com
alterações não commitadas). O backend **já aceita** `escopo` + `appointment_id` em `bulk_adjust`,
então é trabalho só de tela quando aquela frente fechar.

## 12. Segunda leva (2026-07-29): a massa sai, a trilha entra no cartão

Duas mudanças pedidas depois de ver a tela rodando.

### 12.1 "Ajustar sessões" (a massa) saiu da ficha

Sobravam **duas portas para a mesma intenção** — "mudar as próximas sessões" —, e a mais visível era
a mais fraca: a massa mexia em profissional e horário, mas **não** nos dias da semana, e (antes da
D2) nem gravava a grade. O ajuste de grade faz tudo isso.

Removidos: `PackageBulkModal` e seu teste, o item do menu, a action `bulkAdjustPackage` da ficha, a
função e os tipos no BFF, e os testes correspondentes. **Os endpoints `bulk_adjust`/`bulk_cancel`
continuam no backend, testados** — é neles que o B5.3 (escopo a partir da agenda) vai se apoiar; o
motivo ficou escrito no lugar da função, como no precedente do `bulkCancelPackage` (doc 43 §5g).

### 12.2 O cartão ficou fiel à referência

O que mudou desde a primeira leva, comparando com o protótipo:

| | Antes | Agora |
| --- | --- | --- |
| Estrutura | cada pacote num cartão com borda e fundo próprios | blocos **planos separados por linha**, como o `pkgBlock` |
| Progresso | barra de progresso | **trilha de bolinhas** — uma por sessão, com estado |
| Identidade | código + nome | código + **ícone do tipo** + nome |
| Chip | pílula sem ícone | pílula **com ícone** (⚠ Acabando, ⏸ Pausado, ✓ Concluído) |
| Contexto | uma linha | **título + explicação** ("Pacote acabando" / "Faltam 2 sessões para concluir.") |
| Pausado | "as sessões estão fora da agenda" | "**Validade estendida** enquanto pausado. As N sessões seguradas…" |
| Histórico | repetia a caixa de contexto | só contador e trilha — pacote encerrado não pede nada |
| Seção | borda neutra | **borda acende** quando algum pacote está acabando ou completo |

A trilha exigiu backend: `GET /patients/:id/packages` passou a devolver `sessoes` por pacote, com a
trilha de **todos** montada em **uma leitura só** (`sessions_by_package/2`) — buscar por pacote seria
um N+1 que cresce com o tempo de casa do paciente.

**O que a referência mostra e nós não temos:** o "Pausado · **retoma 15/07**". No protótipo a pausa
grava uma data de retomada (hoje + 21 dias); aqui a retomada é manual e não existe esse campo.
Preferi omitir a data a inventar um dado — se a retomada agendada virar produto, é um atributo novo
no `Package` e um job, não um rótulo.

### 12.3 As bolinhas: dois defeitos, um de dado e um de CSS

A primeira versão da trilha saiu errada na tela — bolinhas a mais e desalinhadas. Duas causas
independentes, e a primeira **provada no dado real** que gerou o print:

```
 nome    | total | status | presenca  | count
---------+-------+--------+-----------+-------
 Pacotao |     6 | ativo  | cancelada |     6
 Pacotao |     6 | ativo  | prevista  |     6
```

1. **Cancelada entrava na trilha.** Um pacote de 6 tinha **12** presenças: o ajuste de grade
   cancela as futuras e re-materializa, e a retomada e o `−1` fazem o mesmo. O cartão desenhava as
   12, com as canceladas quase invisíveis — o desenho discordando do `0/6` ao lado. **A trilha é a
   série, não o cemitério dela**: o servidor passou a filtrá-las, como o protótipo faz em
   `pkgSessions` ([`:387`](../interface/Movimento.dc.html#L387)). O estado `:cancelada` deixou de
   existir na API e nos tipos do web.
2. **O halo da "próxima" usava `ring-*` do Tailwind.** O utilitário monta a sombra a partir de
   variáveis (`--tw-ring-shadow`) que uma cor inline não alimenta, e o `ring-offset` somava um anel
   branco **por fora** — a bolinha da próxima ficava maior que as vizinhas e desalinhava a fila.
   Virou `box-shadow` inline, como o protótipo (`pkgDot`): sombra não ocupa caixa, então todas
   continuam com 14px.

E um terceiro, achado pelo teste enquanto se consertava o primeiro: **a trilha de um pacote
individual pausado não sabia que estava segurada.** Numa sessão individual quem recebe o `pkg_hold`
é o **bloco** (é a sessão dele), não a presença — então a trilha classificava como
"Próxima/Agendada" sessões que não estavam na agenda de ninguém. O estado do pacote passou a entrar
na classificação; na turma o hold é da presença e o caminho antigo continua valendo.

Suítes desta leva: **1615 testes de backend** e **2033 do web**, verdes; `svelte-check` limpo;
cobertura em 91,9%.
