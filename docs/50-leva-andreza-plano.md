# 50 — A leva da Andreza: separação do trabalho, item a item

Plano de execução do que ficou decidido em [`37-homologacao-andreza.md`](37-homologacao-andreza.md)
(§7 sequenciamento, §8 decisões, §9 detalhamento da agenda). Este doc **não redecide** nada do
§8 — ele quebra o trabalho em frentes fechadas (`AN-01`…`AN-14`), diz o estado real de cada uma
**hoje**, e isola as decisões que ainda travam código.

**Por que ele existe:** o doc 37 foi escrito em **2026-07-23**. Depois dele entraram as Ondas 3, 4,
5 e 6 (docs 41–49, commits `513bca1`…`626a72b`), que mexeram exatamente em algumas das áreas que a
Andreza apontou. **Oito itens mudaram de estado** — um deles inteiro, e um deles muda o *desenho*
da fatia mais importante da leva. Executar o §7 na letra hoje significaria construir coisa que já
existe, deixar de fora coisa que passou a existir, e desenhar o card da agenda contra um modelo de
status que não é mais o de julho.

> **Duas passadas.** A §1 é o levantamento contra o código de hoje. A [§2](#2-conflitos-abertos-na-árvore-agora)
> é o que está **aberto na árvore de trabalho neste momento** e precisa ser resolvido antes de a
> leva começar — não é backlog, é bloqueio.

---

## 1. O que mudou desde o doc 37 (re-baseline)

### 1a. Mudou o escopo — item que saiu ou encolheu

| # | Item do doc 37 | Estado lá (23/07) | Estado hoje | Evidência |
| --- | --- | --- | --- | --- |
| 1 | **D-H8 / HOM-024** — prévia de impacto em mudança estrutural | "o mais caro do relatório", item **7** do §7 | ✅ **FEITO** — motor, gate nas 4 portas, 409 e modal nas 4 telas | Onda 6, Frente 8 ([`48 §5`](48-onda-6-soltas-e-limpeza.md)); `Api.Scheduling.ImpactAnalysis`, [`future_conflicts/2`](../api/lib/api/scheduling.ex#L1426), [`ConflictsModal.svelte`](../web/src/lib/components/scheduling/ConflictsModal.svelte) |
| 2 | **HOM-010** — presença da turma parecia única | ✅ no modelo, ⬜ invisível na UI (tarefa de descoberta do D-H11) | ✅ **visível** — a presença é por participante no drawer | A2/Frente 6 ([`41`](41-turma-presenca-por-participante.md)); [`AppointmentDrawer.svelte:86-110`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L86) |
| 3 | **HOM-013** — duplicado só por CPF | ⬜ faltava telefone e nome+nascimento | ✅ **CPF + telefone** já avisam; sobra só nome+nascimento | [`PatientForm.svelte:112-120`](../web/src/lib/components/patients/PatientForm.svelte#L112), [`lookup/+server.ts`](../web/src/routes/api/patients/lookup/+server.ts) |
| 4 | **D-H7** — papéis em inglês na UI | ⬜ rótulos a criar | ✅ **já em português**, de fonte única — mas com palavras **diferentes** das decididas | [`members.ts:28-47`](../web/src/lib/members.ts#L28) |
| 5 | **D-H3** — motivo nas três ações críticas | "hoje só `cancel` tem campo" | ✅ o cancelamento está **inteiro** (backend + a UI que pergunta) — sobram **duas** das três | `9d594ff` (Frente 4); [`AppointmentDrawer.svelte:134-142,394,437`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L134) |

### 1b. Mudou o desenho — item que agora se faz de outro jeito

| # | O que mudou | Por que importa para a leva | Evidência |
| --- | --- | --- | --- |
| 6 | **Pacotes existe** (Frente 5, doc 09) | HOM-005(parte), **019 e 020 ganharam alvo** — no doc 37 eram ➖ "não se aplica". Vira `AN-14` | commit `cb86851`; [`api/lib/api/packages/`](../api/lib/api/packages/) |
| 7 | **A tarja de pacote sumiu do card** — `appointments.package_id` foi removida, morta desde a A2 | O §9.1 item 4 dizia "a faixa lateral é do pacote, a troca é livre". **Não há faixa nenhuma**: a cor do profissional entra em espaço vazio, e a linha 1 tem **6 sinais, não 7** | `aec7ba4`; [`AppointmentBlock.svelte`](../web/src/lib/components/agenda/AppointmentBlock.svelte) |
| 8 | **O status do bloco virou ROLLUP das presenças** — as ações `mark_completed`/`mark_missed` do bloco foram aposentadas | 🔴 **conflita de frente com o redesenho do card.** Ver [§4.2](#42-o-conflito-novo-o-badge-de-status-mente-numa-turma-mista) — é a decisão **D13** | `19ceacc`; [`Attendance.Rollup`](../api/lib/api/scheduling/attendance/rollup.ex) |

**O que isso faz com o §7:** dos 11 itens, um saiu inteiro (o 7), um encolheu para "só a matriz"
(o 6), um encolheu pela metade (o 10) e um encolheu para dois terços (o 3). Entrou `AN-14`, e a
fatia 1 — a mais importante — ganhou uma decisão de produto que não existia em julho.

### 1c. Verificado e **não** é problema

Coisas que eu suspeitei que fossem conflito e não são — registradas para ninguém gastar a suspeita
de novo:

- **CSP × o link de WhatsApp (`AN-02`).** A CSP é `default-src: 'self'` + `form-action: 'self'`
  ([`svelte.config.js:21-34`](../web/svelte.config.js#L21)). CSP **não governa navegação de
  topo**, então uma âncora para `wa.me` passa. Só não implementar como *submit de formulário*, que
  o `form-action` barraria;
- **`who_fits` continua síncrono** no `GET /api/waitlist/candidates`
  ([`waitlist_controller.ex:136-152`](../api/lib/api_web/controllers/waitlist_controller.ex#L136)) —
  o "#52 who_fits→Oban" da Onda 4 foi do **fan-out da notificação**, não do endpoint. `AN-12`(a)
  segue sendo só tela;
- **Semana e Mês não herdam o redesenho.** Só [`ListView`](../web/src/lib/components/agenda/ListView.svelte)
  e o drawer consomem `STATUS_META`; Semana/Mês usam `OccupancyBar` e contagem. O escopo do
  `AN-01` fora da visão Dia é pequeno de verdade.

---

## 2. Conflitos abertos na árvore **agora**

`git status` não está limpo, e o que está aberto é do A3 — a frente que o doc 37 achava que estava
por fazer e a Onda 6 entregou.

**`api/lib/api/scheduling.ex` está modificado e não commitado** (24 inserções, 21 remoções). A
mudança troca o contrato de `future_conflicts/2`:

| | Antes (commitado) | Depois (na árvore) |
| --- | --- | --- |
| Resposta | `%{conflicts: [...], truncado?: bool}` | `%{conflicts: [...], total: n}` |
| Teto | 500 agendamentos **lidos** | 10 conflitos **detalhados**, `total` exato |

É uma boa mudança — responde ao [D2 do doc 48](48-onda-6-soltas-e-limpeza.md#d2--o-teto-de-500-agendamentos-da-análise-de-impacto)
("o teto é escolha, não medição") e troca "e possivelmente mais" por um número real. **Mas está
pela metade**, e as três pontas soltas quebram em silêncio:

1. **O HTTP ainda fala o contrato velho.** [`tenant_scope.ex:121`](../api/lib/api_web/tenant_scope.ex#L121)
   monta o `meta` com `truncado: analise[:truncado?] == true` — chave que **não existe mais** no mapa.
   Resultado: `truncado` vira `false` sempre e o `total` **nunca chega na resposta**;
2. **O web ainda lê o contrato velho.** [`scheduling-conflicts.ts:26,49,79-86`](../web/src/lib/scheduling-conflicts.ts#L26)
   tipa e parseia `truncado`, e o `resumoConflitos` decide o "(e possivelmente mais)" por ele. Com
   a mudança, o aviso de lista incompleta **desaparece da tela** sem ninguém notar — a modal
   mostrará 10 conflitos como se fossem todos;
3. **O moduledoc novo cita um módulo que não existe.** Ele manda ver
   `Api.Scheduling.ScheduleException.Changes.CheckFutureConflicts`; `grep` na `api/` inteira só
   encontra a própria menção. As três portas de exceção continuam no `gate_de_conflitos/3` da
   fronteira ([`:1729`](../api/lib/api/scheduling.ex#L1729), [`:1768`](../api/lib/api/scheduling.ex#L1768),
   [`:1878`](../api/lib/api/scheduling.ex#L1878)); só `update_clinic_hours/2` ganhou o recheck
   dentro da transação.

**O que fazer:** decidir se essa mudança **fecha** (propagar `total` até o `ConflictsModal`, criar
o `CheckFutureConflicts` ou corrigir o moduledoc, ajustar os testes dos dois lados) ou **volta**
(`git checkout`). Nas duas saídas é trabalho de minutos a uma hora — mas **não começar a leva por
cima disso**: a `AN-01` mexe em agenda, e um `git stash` no meio de uma fatia grande é como se
perde mudança boa.

---

## 3. Placar do que sobra

| Frente | O quê | Tamanho | Trava em decisão? |
| --- | --- | --- | --- |
| `AN-01` | **Gramática visual do card da agenda** (HOM-002→006) | **G** | ✅ 4 decisões |
| `AN-02` | Botão de confirmação honesto (D-H4) | **P** | ✅ 1 decisão |
| `AN-03` | Motivo em **falta e remarcação** (D-H3) | **M** | ✅ 1 decisão |
| `AN-04` | Telefone obrigatório em paciente e profissional (D-H5) | **P** | ✅ 1 decisão (legado) |
| `AN-05` | Fórmula do KPI na tela (HOM-021) | **P** | — |
| `AN-06` | Rótulos dos papéis + matriz de acesso (D-H7) | **P** | ✅ 1 decisão |
| `AN-07` | `veio_da_fila` + `dias_na_fila` (D-H10) | **P** | — |
| `AN-08` | Acessibilidade e responsividade (HOM-028) | **M/G** | ✅ 1 decisão (gate) |
| `AN-09` | Trilha em cadastros + descoberta da auditoria (HOM-016) | **M** | ✅ 1 decisão (alcance) |
| `AN-10` | Duplicado por nome + nascimento (HOM-013, resto) | **P** | — |
| `AN-11` | Validação de CPF/e-mail/nascimento (HOM-012) | **P** | ✅ 1 decisão |
| `AN-12` | Fila: UI "quem cabe aqui" + registro da oferta (HOM-017/018) | **P + M** | ✅ 1 decisão (cisão) |
| `AN-13` | Rodar o roteiro §06 como QA guiado (HOM-030) | **P** | — |
| `AN-14` | Pacote na agenda: progresso e recorrência (HOM-019/020) | **M** | ✅ 1 decisão |

**Fora por decisão já tomada (não entram):** WhatsApp de verdade (D-H4, depois desta leva), LGPD
versionado (D-H6 ❌), comparativo/meta e drill-down/exportação de relatório (HOM-022/023),
*undo* (HOM-026), glossário escrito para humanos (HOM-027 — barato, mas é doc, não código).

---

## 4. `AN-01` — a gramática visual do card **[G]**

A fatia confirmada como obrigatória. Resolve **HOM-002, 003, 004, 005 e 006** de uma vez, e é a
única do relatório que atinge a tela onde a operação vive o dia inteiro. Alvo: a **Figura 2** do
PDF, com as ressalvas do [§9](37-homologacao-andreza.md#9-a-gramática-visual-da-agenda--o-gap-contra-a-figura-2)
e a decisão nova da [§4.2](#42-o-conflito-novo-o-badge-de-status-mente-numa-turma-mista).

Arquivos: [`AppointmentBlock.svelte`](../web/src/lib/components/agenda/AppointmentBlock.svelte) (165 linhas),
[`DayGrid.svelte`](../web/src/lib/components/agenda/DayGrid.svelte), [`AgendaNav.svelte`](../web/src/lib/components/agenda/AgendaNav.svelte),
[`agenda.ts`](../web/src/lib/agenda.ts) (`STATUS_META`).

### 4.1 O que muda, item a item

| Sub | O que fazer | Hoje | Nota |
| --- | --- | --- | --- |
| a | **Fundo branco sempre**; borda neutra | fundo é `color-mix(status 12%)` / `warning 16%` ([`:76-91`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L76)) | conflito e ação continuam podendo tingir a **borda** |
| b | **Ponto + hora na cor do status** | o ponto é do **profissional** ([`:112`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L112)); a hora é neutra | libera o profissional para o sub `d` |
| c | **Badge textual do status** em todo card | status nunca aparece escrito — só tinta, `dim` e `strike`; o texto só existe no `aria-label` ([`:69`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L69)) | 🔴 **é aqui que mora o D13**. O drawer já faz isso ([`:208`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L208)) |
| d | **Faixa lateral = cor do profissional** + underline no cabeçalho da coluna | **não existe faixa** (a de pacote morreu em `aec7ba4`); cabeçalho tem só o avatar | ficou mais barato que o doc 37 previa |
| e | **"Registrar status"** no lugar de `AÇÃO` | string literal ([`:123`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L123)) | ver **D2** |
| f | **No máximo 2 ícones, com tooltip** | 6 sinais na linha 1: ponto do prof, conflito, badge AÇÃO, ícone do tipo, pulso `live`, badge ENCAIXE — só conflito tem `title` | sobram **conflito** e **encaixe**; ícone do tipo sai (o nome já é a linha 3); pulso vira badge "Em atendimento" |
| g | **"2/4 vagas ocupadas"** em linha própria | `Tipo · 2/4` como título ([`:61`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L61)) | — |
| h | **Legenda da agenda** | não existe (`grep -i legenda` no `web/` = zero) | **2 blocos**, não 7 chips: 6 status + 2 marcadores ortogonais + 1 pendência (§9.3). Ver **D3** |
| i | **Ocupação do profissional no cabeçalho da coluna** | mostra CREFITO e contagem ([`DayGrid:326`](../web/src/lib/components/agenda/DayGrid.svelte#L326)); `OccupancyBar` só é usada em Semana/Mês | componente já existe, é reuso |
| j | **Escada de degradação por altura** | degradação binária (>30px, >58px) | **é o que decide se o resultado se parece com a imagem**. Ver **D1** |

### 4.2 O conflito novo: o badge de status **mente** numa turma mista

Este é o achado da reanálise, e ele muda o desenho — não dava para saber em 23/07 porque o
`19ceacc` é de 25/07.

O `Appointment.status` **deixou de ser escrito por uma ação do bloco** e virou **derivado das
presenças**. A regra está em [`Attendance.Rollup.block_status/2`](../api/lib/api/scheduling/attendance/rollup.ex#L34):

> presenças vivas todas resolvidas → **alguma `:concluida` ⇒ o bloco é `:concluido`**; só se
> **todas** faltaram é que o bloco é `:faltou`.

Numa turma de 4 em que **1 veio e 3 faltaram**, o bloco é `:concluido`. Isso é uma simplificação
consciente e correta enquanto o status é só **tinta de fundo** — ninguém lê um retângulo
esverdeado como "todos compareceram". Mas o sub `c` manda escrever a palavra **"Concluído"** num
badge, e aí a simplificação vira **afirmação falsa na tela**: exatamente o "um sinal representando
mais de uma dimensão" que o HOM-002 denuncia, e o "status da turma interpretado como único" do
HOM-010, que demos por resolvido.

O redesenho não cria o problema — ele **torna legível** um compromisso de modelagem que hoje está
escondido. Por isso a decisão **D13** precisa sair antes de codar o sub `c`.

### 4.3 Restrições de implementação (aprendidas caro, não repetir)

- **`data-appt` e `data-appt-id` são contrato do arraste.** O `DayGrid` localiza o bloco por esses
  atributos ([`:190`, `:269`](../web/src/lib/components/agenda/DayGrid.svelte#L190)); reestruturar o
  DOM do card sem preservá-los quebra o drag-and-drop, que tem teste mas passou por um
  `fix` próprio (`01e1296`, "conserta freeze do effect loop");
- **a agenda re-renderiza em tempo real.** Qualquer `$effect` novo no card entra no mesmo laço que
  já congelou a tela uma vez — a lição da casca tempo-real dos Pacotes (guard anti-loop);
- **a paleta é duplicada de propósito, com tripwire.** Se o sub `f` mexer no ícone/cor do tipo de
  atendimento, os dois lados têm teste que fixa a lista e manda mudar a outra ponta junto
  ([D3 do doc 48](48-onda-6-soltas-e-limpeza.md#d3--a-paleta-continua-duplicada-entre-as-linguagens));
- **a barra da agenda já ganhou um morador** — o `DayViewers` do F5 (quem mais está com o dia
  aberto) vive no `AgendaNav`, que é um `flex-wrap` de uma linha
  ([`AgendaNav.svelte:47-83`](../web/src/lib/components/agenda/AgendaNav.svelte#L47)). A legenda do
  sub `h` **não** disputa espaço com ele se entrar como faixa própria **abaixo** da barra.

### 4.4 O que herda de graça, e o que fica de fora

**Herda:** `ListView` e o drawer, que já consomem `STATUS_META` — ganham o badge textual sem
trabalho extra.

**Fica de fora:** "Sessão 2 de 4" (é `AN-14`/D12), cor de profissional configurável, redesenho de
Semana/Mês (usam `OccupancyBar`, não o card), e o controle de densidade do protótipo (código morto lá).

Testes: `AppointmentBlock.svelte.test.ts` e `DayGrid.svelte.test.ts` — o gate do web é 80/75.

---

## 5. As demais frentes

### `AN-02` — O botão de confirmação para de mentir **[P]**
**D-H4.** Hoje o rodapé do drawer dispara `onToast('Confirmação enviada por WhatsApp')` sem enviar
nada ([`AppointmentDrawer.svelte:172`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L172)) —
herança do protótipo. É risco de piloto: a recepção clica, lê "enviada" e acredita.
A CSP não atrapalha (§1c). Custo: minutos a poucas horas, conforme **D4**.

### `AN-03` — Motivo em falta e remarcação **[M]**
**D-H3** — motivo em todas as ações críticas, **sempre opcional**, texto livre (sem taxonomia).
**Encolheu para dois terços:** o cancelamento está inteiro desde a Frente 4 (`9d594ff`) — backend,
a confirmação que **pergunta** o motivo e a exibição depois do fato. Ele é o **molde a copiar**.

E **mudou de lugar**: com a A2 a falta deixou de ser do bloco e passou a ser da presença. Então:

- **falta** → campo novo em [`Attendance`](../api/lib/api/scheduling/attendance.ex) (hoje aceita só
  `[:status, :falta_justificada]`, [`:138`](../api/lib/api/scheduling/attendance.ex#L138)) — o motivo
  é **por participante**, a única leitura coerente numa turma de 4 (**D5**);
- **remarcação** → não registra nada ([`appointment.ex:317-336`](../api/lib/api/scheduling/appointment.ex#L317)) — campo novo.

Backend: 2 colunas + 2 argumentos + migration. A trilha já cobre os dois recursos (`TrailMixin`).
**Aceito conscientemente (§8):** como o preenchimento é voluntário, qualquer filtro por causa nasce
incompleto.

### `AN-04` — Telefone obrigatório em paciente e profissional **[P]**
**D-H5.** Hoje `tel` é opcional nos dois ([`patient.ex:207`](../api/lib/api/records/patient.ex#L207),
[`professional.ex:181`](../api/lib/api/directory/professional.ex#L181)); só `nome` é obrigatório.
Rascunho **não** entra (decisão do §8). O que trava é o **legado** — ver **D6**.

### `AN-05` — A fórmula do KPI na tela **[P]**
**HOM-021.** A definição de ocupação é canônica e não-óbvia (**minutos ocupados ÷ minutos de
expediente**, não "9 slots" — doc 33) e não aparece em lugar nenhum: só há dois `title=` na tela
([`relatorios/+page.svelte:154,312`](../web/src/routes/(app)/relatorios/+page.svelte#L154)).
Melhor razão valor/custo depois do `AN-01`: evita a dona contestar o número.

### `AN-06` — Rótulos dos papéis + matriz de acesso **[P]**
**D-H7, quase feito.** `ROLE_META` já é fonte única e já está em português
([`members.ts:28`](../web/src/lib/members.ts#L28)), consumido por `RoleBadge`, `MemberModal`,
`UserMenu` e `/perfil` — nenhum `owner` cru vaza para a tela. **Mas as palavras diferem das
decididas** no §8:

| Valor no banco | Hoje na UI | Decidido no §8 |
| --- | --- | --- |
| `owner` | Dona | Proprietária |
| `admin` | Administrador | Administração |
| `profissional` | Profissional | Fisioterapeuta |
| `recepcao` | Recepção | Recepção |

Ver **D7**. Sobra, de qualquer forma, a **matriz de acesso publicada** — hoje ela só existe
espalhada nas policies.

### `AN-07` — `veio_da_fila` + `dias_na_fila` no agendamento **[P]**
**D-H10.** Duas colunas, preenchidas na conversão, onde a entry ainda está em mãos antes do
`destroy` ([`waitlist_controller.ex:183`](../api/lib/api_web/controllers/waitlist_controller.ex#L183));
o `dias_na_fila` já é calculado ([`waitlist_json.ex:21`](../api/lib/api_web/waitlist_json.ex#L21)).
Nenhuma migração de dado. **O que não resolve, e foi aceito:** quem sai da fila **sem** agendar
continua sendo apagado.

### `AN-08` — Acessibilidade e responsividade **[M/G]**
**HOM-028.** Nunca medimos nada: nem teclado, nem foco, nem contraste, nem zoom 200%, nem mobile
real (o `docs/34` foi só desktop). Não há `axe` no repo. Duas metades: **auditar** as telas
principais e registrar o achado; e **gate** automatizado — o único item do relatório que a suíte
pode passar a cobrir. Ver **D8**.

> **Sequência importa:** se o `AN-01` for feito primeiro, a auditoria mede o card **novo** e não
> se paga duas vezes. Auditar a agenda antes do redesenho é jogar trabalho fora.

### `AN-09` — Trilha em cadastros + descoberta da auditoria **[M]**
**HOM-016.** O `TrailMixin` só está em `Appointment` e `Attendance` — **cadastro nenhum é
auditado** (paciente, profissional, clínica, membros). Duas metades: **cobrir cadastros** (atenção
ao volume e à poda — [`prune_trail.ex`](../api/lib/api/housekeeping/prune_trail.ex) teria de
alcançar as tabelas novas) e **descoberta** (atalho da própria ficha vale mais que outro item de menu).

**Detalhe de implementação que só aparece lendo o código:** a tela filtra por uma whitelist de
ações em [`audit_controller.ex:24-26`](../api/lib/api_web/controllers/audit_controller.ex#L24) — que
ainda lista `mark_completed`/`mark_missed`/`set_falta_justificada`, ações **que não existem mais**
(deliberado: são rótulos históricos da trilha, `19ceacc`). Cadastro novo = entrada nova nessa lista,
ou o filtro nasce cego.

### `AN-10` — Duplicado por nome + nascimento **[P]**
**HOM-013, o resto.** CPF e telefone já avisam; sobra a heurística por **nome + nascimento**, que é
a que pega o cadastro feito sem documento — o caso comum do balcão.

### `AN-11` — Validação de CPF, e-mail e nascimento **[P]**
**HOM-012 — órfão: não está no §7**, e é barato. Hoje há **máscara** (`maskCpf`, `maskTel`…) e
**zero validação**: no backend `cpf` é `:string` com `max_length: 20`, sem dígito verificador. O
padrão a seguir já existe no repo ([`cnpj.ts`](../web/src/lib/cnpj.ts), alfanumérico). Ver **D10**.

### `AN-12` — Fila: "quem cabe aqui" e o registro da oferta **[P + M]**
**HOM-018 é a fatia mais barata do relatório inteiro:** o backend está pronto e **com zero
consumo** — `Waitlist.who_fits/5` e `GET /api/waitlist/candidates`
([`waitlist_controller.ex:136`](../api/lib/api_web/controllers/waitlist_controller.ex#L136)) não são
chamados por nenhum arquivo do `web/`. Só falta tela.

**HOM-017 é outra coisa e custa mais:** registrar a oferta (`oferecido_em`, canal, resposta,
validade, motivo de recusa). São recursos/colunas novos. Ver **D11** — recomendo cindir.

### `AN-13` — Rodar o roteiro §06 como QA guiado **[P]**
**HOM-030.** Não é código. A defesa de concorrência existe no banco (exclusion constraint GiST +
`version`), mas o roteiro **nunca foi executado pela UI**, e dois cenários nunca foram testados de
forma alguma: **sessão expirada** e **rede instável** pela ótica do usuário.

### `AN-14` — Pacote na agenda: progresso e recorrência **[M]** *(novo — nasce do re-baseline)*
No doc 37 isto era ➖ "não se aplica"; **agora se aplica**, porque Pacotes existe.

- **HOM-020 (progresso)** — "Sessão 2 de 4" existe na **ficha do paciente**
  ([`PackageList`](../web/src/lib/components/patients/PackageList.svelte), `PatientHistory`) e **não**
  na agenda. Como `appointments.package_id` foi removida, levar isso ao card/drawer passa pelo
  `Attendance.package_id` — **tem custo de query**, não é só UI. Ver **D12**;
- **HOM-019 (conflitos de recorrência)** — em boa parte **já resolvido** pelo Preview save-gate da
  Fatia 5 (fora do expediente bloqueia; conflito oferece "agendar mesmo assim"). Sobra conferir se
  o que a série mostra basta — trabalho de verificação, não de construção.

---

## 6. As decisões que travam código

Nenhuma re-abre o §8 — são escolhas de implementação que o §8 deixou para "a fatia". **D13** é a
única genuinamente nova, e nasce do re-baseline. Marquei minha recomendação.

| # | Decisão | Opções | Recomendo |
| --- | --- | --- | --- |
| **D13** 🔴 | **O badge de status numa turma mista** (`AN-01c`, [§4.2](#42-o-conflito-novo-o-badge-de-status-mente-numa-turma-mista)). O rollup diz "Concluído" quando 1 de 4 veio | (a) badge de **composição** no bloco de grupo — "3 de 4 concluídas" em vez da palavra única; (b) badge do status + contador ao lado, como duas informações; (c) manter a palavra única (aceitar a imprecisão por escrito); (d) mudar a regra do rollup | **(a)** — é o que o HOM-005 pede ("contador em texto") e o que o HOM-010 assume; resolve os dois sem tocar em backend. **(d) não**: o rollup foi decidido na A2 e mexer nele reabre a Frente 6 |
| **D1** | **Escada de altura do card** (`AN-01j`). Com `PPM = 1.05`, 30 min = **31 px** e o card da Figura 2 pede ~90 px: a proposta **só cabe** em sessão de 85 min+ | (a) escada de 4 degraus do §9.2; (b) aumentar o `PPM` (grade mais alta, mais rolagem); (c) fidelidade só onde couber | **(a)** — (b) custa rolagem na tela mais usada |
| **D2** | **Um verbo ou dois** (`AN-01e`). A imagem mostra "Registrar status" **e** "Confirmar"; nosso gatilho é um só (RN-58) | (a) só "Registrar status"; (b) criar o gatilho "Confirmar" (regra nova: janela de N horas) | **(a)** — (b) é regra de negócio nova |
| **D3** | **Onde a legenda mora** (`AN-01h`) | (1) faixa fixa (~40 px da tela mais disputada); (2) botão "Entenda as cores" (quem não sabe não clica — foi assim que a auditoria virou HOM-016); (3) faixa recolhível, aberta por padrão, estado em `localStorage` | **(3)**, abaixo da `AgendaNav` (§4.3), com **(1)** de plano B |
| **D4** | **O botão de WhatsApp** (`AN-02`) | (a) desabilitar com "em breve"; (b) abrir a conversa (`wa.me`) / copiar a mensagem **e registrar quem clicou**; (c) deixar como está | **(b)**; (a) se o tempo apertar. **(c) é a única que não recomendo** |
| **D5** | **Onde mora o motivo da falta** (`AN-03`) | (a) na presença (por participante); (b) no bloco (um motivo para a turma inteira) | **(a)** — depois da A2, (b) mente numa turma de 4 (é o mesmo raciocínio do D13) |
| **D6** | **Telefone obrigatório e o legado** (`AN-04`) | (a) obrigar só na criação; (b) obrigar também no update (corrige o legado no fluxo natural); (c) obrigar em tudo + varredura do legado | **(b)** — sem migração de dado |
| **D7** | **Mexer nos rótulos dos papéis?** (`AN-06`) | (a) manter Dona/Administrador/Profissional/Recepção; (b) aplicar o §8: Proprietária/Administração/**Fisioterapeuta**/Recepção | **(a)** — "Fisioterapeuta" amarra o produto a uma especialidade; o resto é sinônimo. A matriz entra de qualquer jeito |
| **D8** | **Acessibilidade vira gate?** (`AN-08`) | (a) auditoria manual, achados viram tarefa; (b) manual + `axe` no CI | **(b)** em **duas etapas** — auditar primeiro; ligar o gate antes de saber o tamanho do buraco pinta o CI de vermelho |
| **D9** | **Alcance da trilha em cadastros** (`AN-09`) | (a) só `Patient` e `Professional`; (b) + `Clinic` e membros/papéis | **(b)** — mudança de papel é o evento mais sensível que temos e hoje não é auditado |
| **D10** | **Validação de CPF barra ou avisa?** (`AN-11`) | (a) avisa e deixa salvar (coerente com "duplicado só avisa"); (b) barra no salvar | **(a)** — CPF de terceiro/estrangeiro/recém-nascido existe no balcão |
| **D11** | **Cindir HOM-017 de HOM-018?** (`AN-12`) | (a) só a UI "quem cabe aqui" nesta leva; (b) UI + registro da oferta | **(a)** — (b) é modelo novo e pode esperar o WhatsApp real, que é quem dá sentido a "canal" e "resposta" |
| **D12** | **Progresso do pacote na agenda** (`AN-14`) | (a) fora desta leva (fica só na ficha); (b) no drawer; (c) no drawer **e** no card | **(b)** — o card está em dieta de sinais no `AN-01`; texto novo lá desfaz o que a fatia acabou de fazer |
| **D14** | **A mudança aberta do A3** ([§2](#2-conflitos-abertos-na-árvore-agora)) | (a) fechar (propagar `total` até a modal + resolver o `CheckFutureConflicts`); (b) reverter e retomar depois | **(a)** — é boa e está quase pronta; mas resolver **antes** da `AN-01`, não durante |

---

## 7. Ordem sugerida

Reordenei o §7 pelo re-baseline. O corte natural é depois do `AN-07`: acima é **antes do piloto**,
abaixo é qualidade que não bloqueia a operação.

**Zero — antes de tudo**

0. `D14` — fechar ou reverter a mudança aberta do A3 **[P]** · não começar fatia grande com a árvore suja

**Antes do piloto**

1. `AN-02` — botão honesto **[P]** · minutos, e é risco operacional real
2. `AN-01` — **gramática visual da agenda [G]** · a crítica mais forte, na tela onde a operação vive
3. `AN-03` — motivo em falta e remarcação **[M]** · o achado de negócio de maior retorno
4. `AN-05` — fórmula do KPI **[P]** · evita contestação do número
5. `AN-04` — telefone obrigatório **[P]**
6. `AN-07` — `veio_da_fila` + `dias_na_fila` **[P]** · duas colunas, e fica caro depois que houver volume

**Depois**

7. `AN-12`(a) — UI "quem cabe aqui" **[P]** · backend pronto e ocioso
8. `AN-06` — matriz de acesso **[P]**
9. `AN-10` + `AN-11` — duplicado por nome+nascimento e validação **[P]** · mesma tela, mesmo PR
10. `AN-09` — trilha em cadastros + descoberta **[M]**
11. `AN-14` — progresso do pacote no drawer **[M]**
12. `AN-08` — acessibilidade **[M/G]** · **depois** do `AN-01`, senão mede o card velho
13. `AN-13` — QA guiado do roteiro §06 **[P]** · fecha a resposta ao relatório

**O que eu cortaria se o piloto tiver data:** `AN-09`, `AN-14` e a segunda metade do `AN-08` —
nenhum impede a clínica de operar, e os três são os que mais consomem sessão.

---

## 8. Resposta ao relatório (não é código, mas é entregável)

Fechada a leva, sobra devolver à Andreza — e o §8 já definiu o teor:

- **HOM-001** atendido por outra marca: é **Cinetra**, não "Moving" (D-H1);
- **HOM-008 / roteiro §06** — "perfil comum não autoriza encaixe" **rejeitado com justificativa**:
  no balcão real quem encaixa é a recepção (D-H2);
- **HOM-029** — LGPD fica como está, **aceito com risco** (D-H6);
- **premissa corrigida**: Pacotes aparecia como "ponto forte" (p. 2) e **não existia** na data do
  relatório — hoje existe, mas não pela recomendação dele;
- **HOM-024** — a prévia de impacto, que ele classificou como "antes do piloto", **foi entregue**
  entre o relatório e esta leva (Onda 6);
- **falsos positivos** (010, 013, 015, 016): existiam e não foram encontrados — três já foram
  tratados como problema de descoberta (§1a);
- **pedir** a planilha de backlog editável (p. 5 e p. 10) e o **HOM-007**, ausente do corpo (D-H12).
