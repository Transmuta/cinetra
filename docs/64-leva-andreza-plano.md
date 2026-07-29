# 64 — A leva da Andreza: separação do trabalho, item a item

Plano de execução do que ficou decidido em [`37-homologacao-andreza.md`](37-homologacao-andreza.md)
(§7 sequenciamento, §8 decisões, §9 detalhamento da agenda). Este doc **não redecide** nada do
§8 — ele quebra o trabalho em frentes fechadas (`AN-01`…`AN-14`), diz o estado real de cada uma
**hoje**, e isola as decisões que ainda travam código.

**Por que ele existe:** o doc 37 foi escrito em **2026-07-23**. Entre ele e hoje (**2026-07-28**)
passaram as Ondas 3–6 **e mais treze fatias** — anexos (`51`), comunicação com o paciente (`52`),
notificações (`53`), auditoria UI (`55`), ficha (`56`), landing/SEO (`57`), deploy (`59`) — além da
auditoria completa (`61`/`62`/`63`), que está **em construção agora**. Executar o §7 na letra
significaria reconstruir coisa entregue e desenhar o card da agenda contra um modelo de status que
não é mais o de julho.

**Placar da revisão:** dos 11 itens do §7, **três saíram inteiros** (feitos entre o relatório e
hoje), **um saiu de escopo por ser maior** (virou fatia própria em construção), **um encolheu**,
e **um item novo entrou**.

---

## 1. O que mudou desde o doc 37

### 1a. Saiu da leva — feito entre o relatório e hoje

| # | Item do doc 37 | Estado lá (23/07) | Hoje | Evidência |
| --- | --- | --- | --- | --- |
| 1 | **D-H8 / HOM-024** — prévia de impacto de mudança estrutural | "o mais caro do relatório", item **7** do §7 | ✅ **feito e depois endurecido** — gate absoluto, contagem real, recheck na hora da escrita | Onda 6 Frente 8 ([`48 §5`](48-onda-6-soltas-e-limpeza.md)) + `dc66340`; `ImpactAnalysis`, [`CheckFutureConflicts`](../api/lib/api/scheduling/schedule_exception/changes/check_future_conflicts.ex), `ConflictsModal` |
| 2 | **D-H4 / HOM-025** — o botão de WhatsApp que mentia | item **2** do §7, "risco de piloto" | ✅ **resolvido de verdade** — não é mais toast falso: envia (e-mail na fase 1, Gupshup na 2) e o paciente responde por **link assinado** | [`52`](52-comunicacao-com-o-paciente.md) + `259a229`; [`AppointmentDrawer.svelte:194`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L194) cita a D-H4 nominalmente |
| 3 | **HOM-010** — presença da turma parecia única | ✅ no modelo, ⬜ invisível na UI | ✅ **visível** — presença por participante no drawer | A2/Frente 6 ([`41`](41-turma-presenca-por-participante.md)) |
| 4 | **HOM-013** (parte) — duplicado só por CPF | ⬜ faltava telefone e nome+nascimento | ✅ **CPF + telefone** avisam; sobra nome+nascimento | [`PatientForm.svelte:112-120`](../web/src/lib/components/patients/PatientForm.svelte#L112) |
| 5 | **D-H7** (parte) — papéis em inglês | ⬜ rótulos a criar | ✅ **já em português**, de fonte única (`Dona · Administrador · Profissional · Recepção`) | [`members.ts:37-52`](../web/src/lib/members.ts#L37) |
| 6 | **D-H3** (parte) — motivo nas ações críticas | "só `cancel` tem campo" | ✅ o **cancelamento** está inteiro (backend + a UI que pergunta) — é o molde a copiar | `9d594ff` |

### 1b. Saiu da leva por ter virado fatia maior

| # | Item | O que aconteceu |
| --- | --- | --- |
| 7 | **HOM-016 / D-H11** — trilha em cadastros + descoberta | Virou **duas fatias próprias**: o redesenho da tela ([`55`](55-auditoria-ui-ux.md), entregue — filtros que a API já tinha e a tela nunca expôs, e a linha que dizia o contrário do que aconteceu) e a **auditoria completa** ([`63`](63-auditoria-completa.md), **em construção agora**: tabela de eventos única, os 9 recursos sem rastro, leitura de ficha, campos sensíveis redigidos, poda de 90 dias). O `AN-09` que eu tinha planejado é um subconjunto disso — **não construir em paralelo** |
| 8 | **HOM-029 / D-H6** — consentimento não governa comunicação | O §8 tinha decidido ❌ "fica como está, porque não há envio". **Agora há envio**, e o consentimento passou a governá-lo: opt-out por canal, três regras de checagem e a decisão de `comunicacao` nascer `true` ([`52 §10-11`](52-comunicacao-com-o-paciente.md); [`patient.ex:267-282`](../api/lib/api/records/patient.ex#L267)). O item (i) do HOM-029 está **atendido**; (ii) e (iii) seguem recusados |

### 1c. Mudou o desenho do que sobrou

| # | O que mudou | Por que importa | Evidência |
| --- | --- | --- | --- |
| 9 | **Pacotes existe** (Frente 5) | HOM-005(parte), **019 e 020 ganharam alvo** — eram ➖ "não se aplica". Vira `AN-14` | `cb86851`; [`api/lib/api/packages/`](../api/lib/api/packages/) |
| 10 | **A tarja de pacote sumiu do card** | O §9.1 item 4 dizia "a faixa lateral é do pacote". **Não há faixa nenhuma**: a cor do profissional entra em espaço vazio, e a linha 1 tem **6 sinais, não 7** | `aec7ba4` |
| 11 | 🔴 **O status do bloco virou ROLLUP das presenças** | **Conflita de frente com o redesenho do card** — ver [§3.2](#32-o-conflito-o-badge-de-status-mente-numa-turma-mista). Resolvido pela decisão **D13** | `19ceacc`; [`Attendance.Rollup`](../api/lib/api/scheduling/attendance/rollup.ex) |
| 12 | **Mobile entrou por dois caminhos** | A `AN-08` encolhe: a agenda ganhou correção de mobile e a landing foi refeita para telas pequenas. **Acessibilidade (teclado, foco, contraste, zoom) continua em zero** — não há `axe` no repo | `174ef8a`, `32112f6` ([`57`](57-seo-e-performance-da-landing.md)) |

---

## 2. Placar do que sobra

| Frente | O quê | Tamanho | Estado |
| --- | --- | --- | --- |
| `AN-01` | **Gramática visual do card da agenda** (HOM-002→006) | **G** | ✅ **construído** ([§3.5](#35-o-que-foi-construído-2026-07-28)) |
| `AN-03` | Motivo em **falta e remarcação** (D-H3) | **M** | ✅ **construído** ([§4a](#4a-o-que-foi-construído-an-03-04-05-e-07)) |
| `AN-04` | Telefone obrigatório em paciente e profissional (D-H5) | **P** | ✅ **construído** |
| `AN-05` | Fórmula do KPI na tela (HOM-021) | **P** | ✅ **construído** |
| `AN-06` | Matriz de acesso — **tela no produto** (D-H7, resto) | **P** | ✅ **construído** ([§4c](#4c-o-que-foi-construído-an-06-08-10-e-11)) |
| `AN-07` | `veio_da_fila` + `dias_na_fila` (D-H10) | **P** | ✅ **construído** |
| `AN-08` | **Acessibilidade** — o mobile já foi (HOM-028, resto) | **M** | ✅ **auditada + consertos** ([doc 76](76-acessibilidade-auditoria.md); gate do CI pende das decisões de paleta) |
| `AN-10` | Duplicado por nome + nascimento (HOM-013, resto) | **P** | ✅ **construído** ([§4c](#4c-o-que-foi-construído-an-06-08-10-e-11)) |
| `AN-11` | Validação de CPF/e-mail/nascimento (HOM-012) | **P** | ✅ **construído** ([§4c](#4c-o-que-foi-construído-an-06-08-10-e-11)) |
| `AN-12` | Fila: UI "quem cabe aqui" (HOM-018) | **P** | ✅ **construído** ([§4b](#4b-o-que-foi-construído-an-12)) |
| `AN-13` | Rodar o roteiro §06 como QA guiado (HOM-030) | **P** | pronto — a única que resta |
| `AN-14` | Pacote na agenda: progresso (HOM-019/020) | **M** | ✅ **construído** — entregue pelo redesenho do drawer ([doc 75](75-drawer-do-agendamento.md)): selo `3/10` no card individual, pacote por participante no drawer, na forma exata da D12 |

**Todas as 11 entram nesta leva**, na ordem da [§6](#6-ordem-sugerida).

**Saíram:** `AN-02` (feito, doc 52) e `AN-09` (virou o doc 63, em construção).

**Fora por decisão já tomada:** LGPD versionado e field policy em médico/CRM (D-H6, itens ii e iii),
comparativo/meta e drill-down de relatório (HOM-022/023), *undo* (HOM-026), glossário escrito (HOM-027).

---

## 3. `AN-01` — a gramática visual do card **[G]** ▶ decidido

A fatia confirmada. Resolve **HOM-002 a 006** de uma vez, e é a única do relatório que atinge a
tela onde a operação vive o dia inteiro. Alvo: a **Figura 2** do PDF, com as ressalvas do
[§9 do doc 37](37-homologacao-andreza.md#9-a-gramática-visual-da-agenda--o-gap-contra-a-figura-2).

Verificado hoje: [`AppointmentBlock.svelte`](../web/src/lib/components/agenda/AppointmentBlock.svelte)
segue com 165 linhas, `AÇÃO` literal na `:123`, fundo tingido por status na `:76`, ponto do
profissional na `:112` e `PPM = 1.05` no [`DayGrid:76`](../web/src/lib/components/agenda/DayGrid.svelte#L76).
Nada disso mudou desde julho.

### 3.1 O que muda, item a item

| Sub | O que fazer | Hoje |
| --- | --- | --- |
| a | **Fundo branco sempre**; borda neutra (só conflito e ação a tingem) | fundo é `color-mix(status 12%)` / `warning 16%` ([`:76-91`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L76)) |
| b | **Ponto + hora na cor do status** | o ponto é do **profissional**; a hora é neutra |
| c | **Badge textual do status** — ver [§3.2](#32-o-conflito-o-badge-de-status-mente-numa-turma-mista) | status nunca aparece escrito; o texto só existe no `aria-label` |
| d | **Faixa lateral = cor do profissional** + underline no cabeçalho da coluna | não existe faixa (a de pacote morreu em `aec7ba4`) |
| e | **"Registrar status"** no lugar de `AÇÃO` | string literal ([`:123`](../web/src/lib/components/agenda/AppointmentBlock.svelte#L123)) |
| f | **No máximo 2 ícones, com tooltip** | 6 sinais na linha 1; só conflito tem `title`. Ficam **conflito** e **encaixe**; o ícone do tipo sai (o nome já é a linha 3) e o pulso vira badge "Em atendimento" |
| g | **"2/4 vagas ocupadas"** em linha própria | `Tipo · 2/4` como título |
| h | **Legenda** em faixa recolhível | não existe (`grep -i legenda` no `web/` = zero) |
| i | **Ocupação do profissional no cabeçalho da coluna** | mostra CREFITO e contagem; `OccupancyBar` só é usada em Semana/Mês |
| j | **PPM 2.55** + escada residual para 15 min | `PPM = 1.05` |

### 3.2 O conflito: o badge de status **mente** numa turma mista

O `Appointment.status` deixou de ser escrito por ação do bloco e virou **derivado das presenças**
([`Rollup.block_status/2`](../api/lib/api/scheduling/attendance/rollup.ex#L34)): presenças vivas
todas resolvidas → **alguma `:concluida` ⇒ o bloco é `:concluido`**; só se **todas** faltaram é que
o bloco é `:faltou`.

Numa turma de 4 em que **1 veio e 3 faltaram, o bloco é "Concluído"**. Isso passa despercebido
enquanto o status é só tinta de fundo — ninguém lê um retângulo esverdeado como "todos vieram". Mas
o sub `c` manda **escrever a palavra**, e aí a simplificação vira afirmação falsa na tela: o próprio
HOM-002 que a fatia existe para consertar. O redesenho não cria o problema — ele **torna legível**
um compromisso que hoje está escondido.

### 3.3 Decisões tomadas (2026-07-28)

| # | Decisão | Escolha |
| --- | --- | --- |
| **D13** | Badge numa turma mista | ✅ **Badge de composição** — o bloco de grupo mostra "3 de 4 concluídas" em vez da palavra única; o individual mantém a palavra. Resolve HOM-005 e HOM-010 junto, sem tocar no backend |
| **D1** | Altura do card | ✅ **PPM 1.6** — revisado para baixo depois de medir (ver [§3.6](#36-o-que-só-a-inspeção-visual-mostrou)). A escolha inicial de `2.55` deixava **65px de folga** num card cujo conteúdo ocupa 61 |
| **D2** | Um verbo ou dois | ✅ **Só "Registrar status"** — zero regra nova. "Confirmar" exigiria um gatilho novo (janela de N horas) e fica para depois |
| **D3** | Onde a legenda mora | ✅ **Faixa recolhível abaixo da barra**, aberta por padrão, estado em `localStorage`. Dois blocos: 6 status + 2 marcadores ortogonais (conflito, encaixe) + 1 pendência |

### 3.4 Restrições de implementação (aprendidas caro)

- **`data-appt` e `data-appt-id` são contrato do arraste** — o `DayGrid` acha o bloco por eles
  ([`:190`, `:269`](../web/src/lib/components/agenda/DayGrid.svelte#L190)). Reestruturar o DOM sem
  preservá-los quebra o drag-and-drop, que já teve um `fix` só para ele (`01e1296`);
- **o PPM 2.55 toca mais gente do que o card** — a mesma constante governa `topDe`, a altura da
  grade, o fantasma do arraste, o `dropMinutes` e as faixas de indisponibilidade. É uma constante,
  mas com sete usos: todos precisam de conferência visual, não só de teste;
- **a agenda re-renderiza em tempo real** — `$effect` novo no card entra no mesmo laço que já
  congelou a tela uma vez (lição da casca tempo-real dos Pacotes);
- **a paleta é duplicada de propósito, com tripwire** nos dois lados ([D3 do doc 48](48-onda-6-soltas-e-limpeza.md#d3--a-paleta-continua-duplicada-entre-as-linguagens));
- **a barra da agenda já tem morador** — o `DayViewers` do F5 vive no `AgendaNav`, um `flex-wrap` de
  uma linha. A legenda entra **abaixo**, sem disputar espaço.

### 3.5 O que foi construído (2026-07-28)

| Peça | Onde |
| --- | --- |
| `statusSignal/2` — o motor do D13 | [`agenda.ts`](../web/src/lib/agenda.ts) — decide entre a palavra do status e a composição; **ponto e badge saem dele**, para cor e texto nunca contarem histórias diferentes |
| Card redesenhado | [`AppointmentBlock.svelte`](../web/src/lib/components/agenda/AppointmentBlock.svelte) — fundo branco, badge textual, faixa do profissional, 2 ícones com rótulo, "Registrar status", "N/M vagas ocupadas", escada de 4 degraus |
| `PPM 2.55` + cabeçalho | [`DayGrid.svelte`](../web/src/lib/components/agenda/DayGrid.svelte) — sublinhado na cor do profissional e `OccupancyBar` reusando o `occupancyRate` (a fórmula única, A-D12) |
| Legenda em dois blocos | [`AgendaLegend.svelte`](../web/src/lib/components/agenda/AgendaLegend.svelte) — recolhível, `localStorage`, montada só em Dia/Lista |

**Verde:** 1637 testes do web, cobertura 90,36% stmts / 75,46% branch (gate passa), `svelte-check`
sem erro novo. 34 testes cobrem a fatia (29 do card + 5 da legenda).

**Uma inversão deliberada:** o protótipo mandava `AÇÃO > conflito` na tinta do bloco. Como as duas
não disputam mais o mesmo canal — a pendência tem o badge inteiro, ao conflito sobra um ícone de
11px —, a **borda passou a ser do conflito**. Deixá-la na pendência sinalizaria a pendência duas
vezes e o conflito nenhuma.

### 3.6 O que só a inspeção visual mostrou

A suíte não pega leiaute, e o §3.4 avisava que o `PPM` precisava de conferência visual. Duas
coisas apareceram na imagem e em nenhum teste:

1. **A linha de vagas estava desgrudada.** Ela tinha `mt-auto`, herdado de quando o card era baixo.
   Com 126px de altura a folga vai toda para o meio, e a linha ficava colada no rodapé — na tela
   parecia legenda do bloco de baixo. Corrigido: as quatro linhas ficam juntas no topo;
2. **O card de 50 min tinha 126px para 61 de conteúdo.** Registrado como sobra visível — e foi o
   que levou à revisão abaixo.

### 3.6a. A revisão do PPM: o que a medição mostrou

O `2.55` saiu de uma conta de guardanapo ("o card da Figura 2 pede ~90px"). Medindo a altura
**natural** de cada variante no browser — soma dos filhos + `py-1` + os `gap-0.5` —, os números
reais são outros:

| Variante | Precisa | Quem usa |
| --- | ---: | --- |
| compacta (hora + nome na mesma linha) | **24px** | 15 min |
| 2 linhas (hora+badge · nome) | **44px** | 30 min |
| 3 linhas (+ tipo) | **61px** | individual de 50 e 60 min |
| 4 linhas (+ vagas) | **78px** | **só turma** — o card individual nunca tem a quarta |

A última linha é a chave: `{#if linhas > 3 && grupo}`. **O card individual nunca usa a quarta
linha**, então dimensionar a grade inteira por ela inflava tudo por um caso que é minoria.

**Dois defeitos que só a medição pegou**, ambos invisíveis (nada quebra, nada estoura):

1. **dois dos três limiares cortavam texto.** O card é `flex flex-col` com `overflow-hidden`:
   quando não cabe, os filhos **encolhem** em vez de transbordar. O nome do card de 30 min estava
   sendo renderizado com **9px em vez de 18** — metade do texto sumia e a tela não denunciava.
   Os limiares chutados eram `76/44/30`; os medidos são `78/61/44`;
2. **a escada comparava a altura errada.** O `style` desenha `height - 2` (a folga entre blocos
   vizinhos) e a conta usava o `height` de entrada — 2px que não existem na tela, o bastante para
   o card de 30 min pedir duas linhas num espaço de uma.

**Resultado (medido, `PPM = 1.6`):**

| Duração | Altura | Variante | Folga |
| --- | ---: | --- | ---: |
| 15 min | 22px | compacta | −2 |
| 30 min | 46px | 2 linhas | +2 |
| 50 min | 78px | 3 linhas | +17 |
| 50 min (turma) | 78px | 4 linhas | +2 |
| 60 min | 94px | 3 linhas | +33 |

**A grade caiu de 1554px para 984px** (−37%), contra os 830px de antes da fatia — ou seja, o custo
do redesenho ficou em ~19% de rolagem a mais, e não nos 87% que o `2.55` cobrava. O único déficit
que sobra são 2px na sessão de 15 min, que é curta demais para qualquer densidade razoável e vive
do `title`/`aria-label`.

**Por que 1.6 e não 1.5:** a 1.5 o card de 30 min renderiza 43px e cai na variante compacta — perde
o nome em 12px, que é a informação mais lida da grade. 1.6 é o menor valor em que ele ainda cabe.

### 3.7 O que herda, e o que fica de fora

**Herda de graça:** `ListView` e o drawer, que já consomem `STATUS_META` — ganham o badge textual
sem trabalho extra.

**Fica de fora:** "Sessão 2 de 4" (é `AN-14`), cor de profissional configurável, redesenho de
Semana/Mês (usam `OccupancyBar`, não o card).

---

## 4. As demais frentes

### 4a. O que foi construído (`AN-03`, `04`, `05` e `07`)

O bloco "antes do piloto" fechado em 2026-07-28, na ordem da [§6](#6-ordem-sugerida).

| Frente | Peças |
| --- | --- |
| `AN-05` | A fórmula de cada um dos 5 KPIs no `title` do cartão + ícone de ajuda com `aria-label` ([`relatorios/+page.svelte`](../web/src/routes/(app)/relatorios/+page.svelte)). Copiadas **literalmente** de `summary_totais/5` |
| `AN-04` | [`Api.Validations.TelObrigatorio`](../api/lib/api/validations/tel_obrigatorio.ex) — módulo **compartilhado** entre `Patient` e `Professional`; `telefoneValido/1` em [`telefone.ts`](../web/src/lib/telefone.ts) espelhando `Dispatch.normalizar/2`; asterisco, guard de salvar e rodapé nos dois formulários |
| `AN-03` | `Attendance.motivo` (por participante) + `Appointment.reschedule_reason` (do bloco) + migration + `ConfirmDialog` da falta, no molde do cancelar |
| `AN-07` | `Appointment.veio_da_fila`/`dias_na_fila`, carimbados em `Waitlist.convert/3` **antes** do `dequeue` + migration |

**Verde:** backend 1396 testes (2 falhas pré-existentes, ver abaixo), web 1656 testes, `svelte-check`
sem erro novo.

**Duas decisões de desenho tomadas na implementação:**

- **o motivo da falta ficou na presença; o da remarcação, no bloco.** Não é assimetria por
  descuido: faltar é de uma pessoa (numa turma, três faltam por razões diferentes), remarcar move
  o bloco inteiro (os quatro mudaram de horário pela mesma razão). É o D13 aplicado ao texto;
- **`TelObrigatorio` virou compartilhado em vez de copiado.** A regra é idêntica letra por letra
  nos dois cadastros, e os donos estão em domínios diferentes (`Api.Records` e `Api.Directory`) —
  então mora no nível da aplicação, que é o menor escopo que contém os dois. Uma cópia divergiria
  no primeiro ajuste de mensagem.

**Três achados fora do escopo, encontrados pelo caminho:**

1. 🔴 **a `TelObrigatorio` do paciente quebrou a suíte e2e inteira.** O `criarPaciente` do
   [`e2e/helpers.ts`](../web/e2e/helpers.ts) mandava só `{ nome }`, e o `montarClinica` passou a
   morrer com 422 **antes da primeira asserção** — derrubando todo cenário autenticado, não só os
   de paciente. Consertado. Foi descoberto tentando semear uma clínica para a foto do `AN-01`;
2. **o rodapé dos dois formulários mentia.** O de paciente dizia "Nenhum campo é obrigatório"
   enquanto o rótulo do telefone já trazia o asterisco, na mesma tela. Corrigido nos dois;
3. **duas falhas de RLS pré-existentes** em [`rls_smoke_test.exs`](../api/test/api/rls_smoke_test.exs)
   (`bulk_cancel`/`bulk_adjust` sob GUC). **Provadas alheias**: com a validação do profissional
   stashada, as mesmas duas falham. Ficam para quem cuida da massa de pacote.



### 4b. O que foi construído (`AN-12`)

Fechado em 2026-07-28. A vaga que abriu pergunta à fila, no lugar onde a vaga aparece: o
**drawer** do bloco cancelado/faltou — exatamente o cenário do docstring de `who_fits/5`.

| Peça | Onde |
| --- | --- |
| `fetchCandidates/2` no BFF | [`server/waitlist.ts`](../web/src/lib/server/waitlist.ts) — `GET /api/waitlist/candidates` com o slot `{professional_id, starts_at, ends_at}` |
| `GET /agenda/candidatos` | [`+server.ts`](../web/src/routes/(app)/agenda/candidatos/+server.ts) — buscado quando o drawer abre (molde de `/agenda/mensagens/[id]`); degrada para lista vazia |
| Action `?/agendar_fila` | [`agenda/+page.server.ts`](../web/src/routes/(app)/agenda/+page.server.ts) — a MESMA conversão da fila (`convertEntry`), com o slot do próprio bloco |
| Seção "Quem cabe aqui" | [`AppointmentDrawer.svelte`](../web/src/lib/components/agenda/AppointmentDrawer.svelte) — candidato + `PriorityBadge` + dias na fila + "Agendar" por linha, link "Ver fila"; um form só (padrão do form de presença) |

**Decisões de desenho tomadas na implementação:**

- **"vaga" = bloco `cancelado` ou `faltou`** — os mesmos dois status que o motor de vagas já
  trata como `freed`. A seção não existe em nenhum outro estado;
- **a conversão herda o slot inteiro do bloco** (horário, profissional, tipo, duração) — não há
  formulário: o "quem cabe aqui" é o inverso do "Oferecer" da fila, onde o slot é escolhido;
- **cobrir vaga de falta entra como encaixe por definição**: a exclusion constraint conta o
  `faltou` como ocupante (`status <> 'cancelado'`), então o form parte com o flag armado — e
  para `profissional`, que não marca encaixe (A9/D2), o botão nem oferece o caminho que o
  servidor recusaria;
- **o 422 aparece dentro da seção** (`ConflictErrorBox`): `schedule_conflict` numa vaga de
  cancelamento re-ocupada oferece "Marcar como encaixe"; os demais (ex.: fora do expediente,
  D14) só mostram o motivo. Depois de um "Agendar", a marca da action refaz a consulta — o
  convertido some da lista sem F5.

**Verde:** 1690 testes do web (13 novos na fatia), cobertura 75,88% branch (gate passa),
`svelte-check` sem erro. **Verificado ao vivo** (Clínica Zona Sul, dev): cancelar um bloco fez a
seção nascer com o candidato urgente; "Agendar" criou o bloco no mesmo horário, tirou a entry da
fila, refez a consulta ("ninguém casa") e carimbou `veio_da_fila`/`dias_na_fila` (AN-07); o 422
de expediente apareceu inline. Achado colateral do teste ao vivo: a clínica do seed **não tinha
`clinic_hours` nenhum**, então toda conversão morria em "a clínica não atende neste dia" — dado
de seed, não defeito do produto.

### 4c. O que foi construído (`AN-06`, `08`, `10` e `11`)

Fechados em 2026-07-29, na mesma sessão. Verde: API 1631 testes / 0 falhas, web 2043 testes,
branch 77,26% (gate passa), `svelte-check` 0.

| Frente | Peças |
| --- | --- |
| `AN-11` | [`Api.Cpf`](../api/lib/api/cpf.ex) (módulo 11, irmão do `Api.Cnpj`) + [`CampoValido`](../api/lib/api/records/patient/validations/campo_valido.ex) (cpf/e-mail/nascimento, **barra no salvar** — D10) nas ações create/update do Patient; espelho no web (`cpf.ts`, `emailValido`/`nascimentoValido`) com guard de salvar + rodapé no `PatientForm`; teste que atravessa a fronteira (422 com o campo). Fixtures com CPF inválido (`123.456.789-00`) trocadas por válidos |
| `AN-10` | O lookup de duplicado ganhou o modo `?nome=&nascimento=` — a API busca por nome e o BFF recorta por data igual; o form consulta quando nome (≥3) + nascimento estão preenchidos. Continua **só avisando** (a AN-11 barra formato, não duplicado) |
| `AN-06` | [`Api.Accounts.AccessMatrix`](../api/lib/api/accounts/access_matrix.ex) — a matriz mora **ao lado das policies**, com **tripwire** ([`access_matrix_test.exs`](../api/test/api/accounts/access_matrix_test.exs)): cada linha conferida contra as `can_*?` dos quatro papéis (mudou policy sem mudar matriz → teste quebra). `GET /api/access-matrix` + tabela em Configurações › Equipe (`AccessMatrixTable`). Limite documentado: sondas de LEITURA não existem (policy de read **filtra**, lição do doc 51) — as células `:propria`/leitura são garantidas pelos testes de recorte e pelos 403 dos controllers |
| `AN-08` | Auditoria completa no [doc 76](76-acessibilidade-auditoria.md): axe (públicas), contraste **pelos tokens** (sistêmico), inspeção de foco/teclado. Consertados: divisor "ou" do login (2,1→5,4:1), landing 4,49→5,0, badge ENCAIXE (2,0→8,6:1, texto escuro fixo), **foco de diálogo** (Modal/Drawer: abrir foca, fechar devolve — com regressão). Lista aberta: token `faint` reprova nos 2 temas, branco-sobre-teal, badges de status, teclado da agenda, trap completo, skip link — decisões de paleta que o doc 76 §3 enumera. O gate do CI entra depois delas (D8) |

**Revisão de permissão que a matriz provocou (2026-07-29):** publicar a matriz expôs uma
divergência de produto — a ficha de paciente tinha escrita **só owner/admin** (ADR-016), mas
quem cadastra e corrige no balcão é a **recepção** (o mesmo racional do telefone obrigatório).
Revisado: recepção passou a criar/editar/arquivar ficha (policy + controller + matriz + testes
nos dois níveis); **profissional segue só leitura**, e os textos dos papéis no convite foram
corrigidos para não prometer o contrário. É exatamente o tipo de deriva que o AN-06 existe
para pegar — só que a primeira captura foi na direção oposta: a policy é que estava atrás do
produto.

**Achado colateral 🔴 (fora de a11y, doc 76 §4):** com `RESEND_API_KEY` no ambiente, o primeiro
magic link morria em **500 — `unknown registry: Swoosh.Finch`** (o `runtime.exs` apontava o
cliente HTTP e ninguém subia o pool). Login inteiro quebrado em qualquer ambiente com e-mail
real; consertado no `application.ex` com regressão. E o aviso de ambiente: com a chave no `.env`
de dev, `/dev/mailbox` fica vazio e os **e2e autenticados quebram por timeout** (não skipam).

### `AN-03` — Motivo em falta e remarcação **[M]**
**D-H3** — motivo em todas as ações críticas, **sempre opcional**, texto livre. O cancelamento está
inteiro desde `9d594ff` e é o molde. Com a A2, a falta é **da presença**, não do bloco:

- **falta** → campo novo em [`Attendance`](../api/lib/api/scheduling/attendance.ex) (hoje aceita só
  `[:status, :falta_justificada]`) — por participante;
- **remarcação** → não registra nada ([`appointment.ex:317`](../api/lib/api/scheduling/appointment.ex#L317)).

Reforço vindo do doc 52: o histórico de comunicação **também** ancora na presença, não no bloco —
o motivo da falta no mesmo lugar mantém a ficha coerente.

### `AN-04` — Telefone obrigatório **[P]** — 🟡 metade feita
**O paciente já está pronto**, e exatamente na forma que a D6 escolheu: a
[`TelObrigatorio`](../api/lib/api/records/patient/validations/tel_obrigatorio.ex) roda na criação
**e** no update, a coluna segue anulável e ninguém rodou backfill — a ficha antiga é cobrada no
primeiro save. Fixo (10 dígitos) passa; quem não tem celular recebe por e-mail.

**Falta o profissional** ([`professional.ex`](../api/lib/api/directory/professional.ex) não tem a
validação), que a D6 decidiu incluir.

> ⚠️ **A mudança quebrou a suíte e2e e ninguém percebeu.** O `criarPaciente` do
> [`e2e/helpers.ts`](../web/e2e/helpers.ts) mandava só `{ nome }`, então o `montarClinica` passou a
> morrer com 422 **antes da primeira asserção** — derrubando todo cenário autenticado, não só os
> que olham para paciente. Consertado aqui (o helper manda um número válido). É o padrão que o
> repo já conhece: regra nova que atravessa a fronteira precisa de teste que atravesse a fronteira
> (a lição da Onda 6).

### `AN-05` — A fórmula do KPI na tela **[P]**
Ocupação é **minutos ocupados ÷ minutos de expediente**, não "9 slots" (doc 33), e não aparece em
lugar nenhum: dois `title=` na tela inteira. Conserto barato, evita contestação do número.

### `AN-06` — Matriz de acesso publicada **[P]**
Os rótulos já estão em português e de fonte única. Sobra a **matriz** — o que cada papel vê e
altera —, hoje só existente espalhada nas policies.

### `AN-07` — `veio_da_fila` + `dias_na_fila` **[P]**
Duas colunas, preenchidas na conversão, onde a entry ainda está em mãos antes do `destroy`. O
`dias_na_fila` já é calculado. Nenhuma migração de dado. Quem sai da fila **sem** agendar continua
sendo apagado (aceito no §8).

### `AN-08` — Acessibilidade **[M]** *(encolheu)*
O mobile entrou por outros caminhos (`174ef8a` na agenda, `32112f6` na landing). **Teclado, foco,
contraste e zoom 200% seguem sem nenhuma medição**, e não há `axe` no repo. Fazer **depois** do
`AN-01` — auditar o card velho é jogar trabalho fora.

### `AN-10` — Duplicado por nome + nascimento **[P]**
CPF e telefone já avisam; sobra a heurística que pega o cadastro feito sem documento.

### `AN-11` — Validação de CPF, e-mail e nascimento **[P]**
Há **máscara** e **zero validação** — no backend `cpf` é `:string` sem dígito verificador. O padrão
existe no repo ([`cnpj.ts`](../web/src/lib/cnpj.ts)).

### `AN-12` — UI "quem cabe aqui" **[P]** — ✅ construído
Era a mais barata do relatório: `Waitlist.who_fits/5` e `GET /api/waitlist/candidates` estavam
prontos e **com zero consumo**. A tela foi construída em 2026-07-28 — ver [§4b](#4b-o-que-foi-construído-an-12).

### `AN-13` — Roteiro §06 como QA guiado **[P]**
Não é código. **Sessão expirada** e **rede instável** nunca foram testadas pela ótica do usuário.

### `AN-14` — Progresso do pacote na agenda **[M]**
"Sessão 2 de 4" existe na ficha e não na agenda. Como `appointments.package_id` foi removida, levar
isso ao drawer passa por `Attendance.package_id` — tem custo de query, não é só UI.

---

## 5. Decisões tomadas (2026-07-28)

Seção normativa desta leva. As quatro do `AN-01` estão na [§3.3](#33-decisões-tomadas-2026-07-28).

| # | Decisão | Escolha |
| --- | --- | --- |
| **D5** | Onde mora o motivo da falta (`AN-03`) | ✅ **Na presença, por participante.** Coluna nova em `Attendance`. O bloco mentiria numa turma de 4 — mesmo raciocínio do D13, e casa com o doc 52, que ancorou o histórico de comunicação na presença |
| **D6** | Telefone obrigatório e o legado (`AN-04`) | ✅ **Na criação e na edição, nos dois cadastros.** O legado se corrige no fluxo natural: quem abrir a ficha para mexer em qualquer coisa preenche o telefone junto. Sem migração de dado. Custo aceito: editar ficha velha exige buscar o telefone antes de salvar |
| **D8** | Acessibilidade vira gate? (`AN-08`) | ✅ **Auditar primeiro, `axe` depois.** Auditoria manual → achados viram lista → consertos → só então o gate no CI, já verde. Ligar antes pintaria o CI de vermelho e travaria todo merge |
| **D10** | Validação barra ou avisa? (`AN-11`) | ✅ **Barra no salvar.** CPF inválido não entra no banco. Diverge do padrão "duplicado só avisa" por decisão explícita: dado limpo vale o atrito no balcão, e e-mail errado agora custa confirmação não entregue (doc 52) |
| **D11** | Escopo da fila (`AN-12`) | ✅ **Só a UI "quem cabe aqui".** O registro da oferta (HOM-017) fica fora — mesmo tendo barateado com a máquina de mensagens do doc 52 |
| **D12** | Progresso do pacote (`AN-14`) | ✅ **Drawer e card — mas turma só no drawer.** Bloco individual mostra "Sessão 3 de 10" no card; bloco de grupo mostra **por participante no drawer**, porque numa turma cada um pode estar num pacote diferente e uma linha só no card mentiria (é o D13 outra vez) |
| **AN-06** | Onde mora a matriz de acesso | ✅ **Tela dentro do produto**, em Configurações › Equipe. A clínica consulta sozinha na hora de convidar. Risco a administrar: policy muda e a tela não — a matriz precisa sair de perto das policies, não de prosa escrita à mão |
| **Escopo** | Quantas frentes entram | ✅ **Todas as 11**, na ordem da [§6](#6-ordem-sugerida) |

---

## 6. Ordem sugerida

1. **`AN-01`** — gramática visual da agenda **[G]** · decidido, é o trabalho
2. `AN-05` — fórmula do KPI **[P]**
3. `AN-04` — telefone obrigatório **[P]** · ficou urgente com o doc 52 no ar
4. `AN-03` — motivo em falta e remarcação **[M]**
5. `AN-07` — `veio_da_fila` + `dias_na_fila` **[P]** · fica caro depois que houver volume
6. `AN-12` — UI "quem cabe aqui" **[P]** · backend pronto e ocioso
7. `AN-10` + `AN-11` — duplicado e validação **[P]** · mesma tela, mesmo PR
8. `AN-06` — matriz de acesso **[P]**
9. `AN-14` — progresso do pacote no drawer **[M]**
10. `AN-08` — acessibilidade **[M]** · depois do `AN-01`
11. `AN-13` — QA guiado do roteiro §06 **[P]**

**Não entra em paralelo:** a auditoria completa ([`63`](63-auditoria-completa.md)) está em
construção e cobre o que seria o `AN-09`.

---

## 7. Resposta ao relatório

- **HOM-001** atendido por outra marca: é **Cinetra**, não "Moving" (D-H1);
- **HOM-008 / roteiro §06** — "perfil comum não autoriza encaixe" **rejeitado com justificativa**:
  no balcão real quem encaixa é a recepção (D-H2);
- **HOM-024, HOM-025 e HOM-016** — os três que ele classificou como "antes do piloto" **foram
  entregues** entre o relatório e esta leva (docs 48, 52 e 55/63);
- **HOM-029** — o item (i) mudou de resposta: o consentimento **passou a governar** o envio
  ([`52 §10`](52-comunicacao-com-o-paciente.md)); (ii) e (iii) seguem recusados;
- **premissa corrigida**: Pacotes aparecia como "ponto forte" (p. 2) e **não existia** na data do
  relatório — hoje existe, mas não pela recomendação dele;
- **pedir** a planilha de backlog editável (p. 5 e p. 10) e o **HOM-007**, ausente do corpo (D-H12).
