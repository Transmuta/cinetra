# 75 — O drawer do agendamento: pacote entregue e o que mais está torto

**Data:** 2026-07-29 · **Escopo:** `AppointmentDrawer.svelte` + o cartão do grid
(`AppointmentBlock.svelte`) · **Origem:** pedido "no card da agenda quando é pacote não mostra que
é pacote e nem qual é a sessão", estendido ao drawer.

Complementa o [doc 69](69-pacotes-prototipo-vs-construido.md) (§ "Pacote na agenda (bloco +
drawer)", item 5 do plano de lá) e o [doc 64](64-leva-andreza-plano.md) (AN-01, o redesenho do
cartão; D13, o sinal que não mente na turma).

---

## 1. O que foi entregue

O vínculo sessão↔pacote existia no banco desde a Frente 5 (`Attendance.package_id`, D11: o pacote é
do **participante**, não do bloco) e viajava no JSON como um UUID cru. Um UUID não diz que é pacote,
não diz qual, e não diz que sessão da série é aquela — então **nem o cartão nem o drawer diziam**.
Quem abria a agenda não distinguia uma sessão de pacote de um particular.

**Contrato** (`ApiWeb.AgendaJSON`, por participante):

```json
"package": { "nome": "Pilates 10", "sessao": 3, "total": 10, "restantes": 7, "falta_punitiva": true }
```

Tudo desce como calculate da `Attendance` (`package_nome`, `package_sessao`, `package_total`,
`package_restantes`, `package_falta_punitiva`), no mesmo `SELECT` das presenças. Duas decisões:

- **`sessao` é CONTADA, não gravada.** É "quantas sessões deste pacote começam até esta,
  inclusive", pela relação-irmã `package_siblings` (auto-referência por `package_id`). Um índice
  gravado na criação passaria a mentir na primeira remarcação que trocasse duas sessões de ordem —
  o mesmo motivo pelo qual `usadas` é derivado e não coluna (`package.ex:15`).
- **Um `load` só para as quatro portas** (`Api.Scheduling.bloco_load/0`). O bloco sai por GET, POST,
  transições e push do canal com **uma** serialização; um `load` que divergisse entre elas faria o
  cartão perder o pacote no primeiro clique de presença — defeito que só aparece depois da escrita,
  que é o caminho que nenhum teste do GET percorre. Tem teste dedicado.

**Cartão:** selo teal na terceira linha — `3/10` com o ícone de pacote e o `title` por extenso.
Numa turma com mais de um participante em pacote vira contagem de cabeças (`2`), porque um "3/10"
solto não diria de quem é; o rótulo muda junto com o número, nunca calado.

**Drawer:** duas linhas **dentro de cada participante** (não uma seção do bloco, como no protótipo
`:1879` — lá o vínculo vivia num mapa `pkgOf` do agendamento):

```
📦 Pilates 10 · 3 de 10          ← a linha inteira leva a /pacientes/<id>#pacotes
Falta debita 1 sessão deste pacote
```

A primeira versão era uma caixa teal com borda, preenchimento e **três** linhas — incluindo o saldo
("7 restantes"). Num painel que já tem cartão de paciente, botões de presença e timeline, ela
gritava mais alto que o próprio paciente. Do verde sobrou o ícone de 13px, e o saldo saiu: *quantas
sobram* é pergunta da ficha, não do bloco. **O campo saiu do contrato atrás dela** — `restantes`
deixou de viajar, e com ele a subquery do agregado `usadas` que ele custava em toda leitura da
agenda. Campo sem leitor é payload morto (é o achado C deste mesmo doc, aplicado ao próprio autor).

A segunda linha é `packageDebit` — a pergunta feita em voz alta no balcão, *"isso vai descontar do
pacote dela?"*. Antes do desfecho é **previsão** em tom neutro: dizer "faltar hoje consome uma das
10" **antes** da falta é o que muda a conversa com o paciente. Depois, vira fato com ícone — "Esta
falta debitou 1 sessão" ou "Falta justificada — não debitou".

---

## 2. Achados no drawer (verificados, não impressões)

### A. O chip do header contradiz o cartão numa turma mista — **o mais grave**

O cartão usa `statusSignal(appt, grupo)` desde o AN-01/D13: numa turma de 4 em que 1 veio e 3
faltaram, ele escreve **"1 de 4 concluídas"**, porque `Appointment.status` é um *rollup* cuja regra
é "alguma concluída ⇒ bloco concluído" e a palavra "Concluído" ali seria afirmação falsa.

O drawer não recebeu essa correção: [`AppointmentDrawer.svelte:95`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L95)
usa `STATUS_META[appt.status]` cru. Resultado: **o cartão diz "1 de 4 concluídas" e o drawer que
ele abre diz "Concluído"** — duas verdades para o mesmo bloco, a 400px de distância. É exatamente o
HOM-002 que o AN-01 existiu para consertar, sobrevivendo na outra superfície.

Conserto: trocar por `statusSignal(appt, grupo)`. Uma linha, e a fonte já é única.

### B. "0 falta(s)" — e a mesma informação com duas regras

Na sessão individual o contador aparece mesmo zerado (`faltas != null`, [`:567`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L567));
na turma ele só aparece quando é maior que zero (`{#if p.faltas}`, [`:551`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L551)).
"0 falta(s)" é ruído puro — ninguém age sobre a ausência de falta —, e ter duas regras para o mesmo
fato na mesma tela é como a divergência nasce.

### C. `veio_da_fila` e `dias_na_fila` viajam e ninguém os mostra

Os dois campos são carimbados na conversão da fila, de propósito, "antes de a entry ser apagada"
(D-H10) — e **nenhuma tela do `web/` os lê** (`grep` em `.svelte`: só o `dias_na_fila` da *entry*,
em `/fila` e no "quem cabe aqui"). É dado pago no banco e no payload, invisível.

É justamente o que fecha o ciclo da fila: quem abre o bloco não sabe que aquele horário foi coberto
pela fila, nem que o paciente esperou 6 dias. Uma linha no drawer ("Veio da fila · esperou 6 dias")
paga o custo que já está sendo pago.

### D. Três caixas cinzas iguais dizendo coisas diferentes

`obs` ([`:357`](../web/src/lib/components/agenda/AppointmentDrawer.svelte#L357)) renderiza **sem
rótulo**, enquanto "Motivo do cancelamento" e "Motivo da remarcação" — visualmente idênticas, logo
abaixo — têm rótulo em negrito. Quem vê a primeira caixa não sabe o que ela é.

### E. O telefone é texto morto

`(61) 99999-9999` é um `<span class="font-mono">`. O drawer é a tela de onde a recepção **liga**.
`href="tel:"` (e, com o telefone já validado pelo doc 65, um atalho de WhatsApp) transforma leitura
em ação sem tirar ninguém da agenda.

### F. As ações moram em três zonas

Presença dentro do card do paciente; Remarcar/Cancelar/Reabrir no meio; Enviar confirmação e
Excluir no rodapé. Some-se a isso o botão **"Cancelar sessão" que fica desabilitado exibindo
"Cancelado"** quando o bloco já está cancelado — repetindo o chip do header e ocupando a linha onde
deveria estar o "Reabrir".

Não é bug; é hierarquia plana. Dois botões de largura total com o mesmo peso ("Remarcar" e
"Cancelar") dizem que remarcar e cancelar são a mesma classe de coisa, e não são.

### G. No mobile o drawer engole a data

`Drawer.svelte` é `w-[404px] max-w-full`: em telas estreitas ele cobre a agenda inteira. E o drawer
**não mostra a data** — só `10:00–10:50 (50min)`. No desktop o dia continua visível atrás (no
cabeçalho da agenda); no celular, não. Quem abre um bloco no telefone não sabe de que dia ele é.

### H. Turma longa rola sem fim

Cada participante tem nome, selo, faltas, agora a caixa de pacote, e até três botões. Com 4
participantes o drawer vira uma coluna de rolagem — e quem já foi resolvido (concluído/faltou)
continua ocupando a mesma altura de quem falta resolver.

---

## 3. O que foi feito, e o que ficou

Os sete primeiros **estão no código** (mesma sessão, com teste cada):

| # | Achado | Como ficou |
| --- | --- | --- |
| 1 | A | o chip do header usa `statusSignal(appt, grupo)` — a mesma fonte do cartão. Numa turma mista ele agora escreve "1 de 2 concluídas", e `STATUS_META` saiu do arquivo (era o último uso) |
| 2 | B | falta zero não aparece, regra **única** para solo e turma, e o plural é de gente ("1 falta", "2 faltas" — não "falta(s)") |
| 3 | D | a observação ganhou rótulo, como os dois motivos vizinhos |
| 4 | G | o horário carrega o dia: `seg, 17/08 · 10:00–10:50 (50min)`, e "hoje" quando é o dia corrente (`shortDayLabel`, novo em `$lib/agenda`) |
| 5 | E | o telefone virou `tel:` |
| 6 | C | linha "Origem · Fila de espera · esperou 6 dias" quando `veio_da_fila` |
| 7 | F | "Cancelar sessão" **some** quando o bloco já está cancelado (era um botão desabilitado repetindo o header, na linha onde o "Reabrir" aparece) e deixou de ter o peso do "Remarcar": virou fantasma, o mesmo tratamento que o Excluir do rodapé usa por ser destrutivo |

### Cada status com a sua cor (e isso não era só do drawer)

`agendado` e `cancelado` tinham os dois `tone: null` — "não pinta o fundo" —, e cada tela resolvia
esse nulo como `muted`. Resultado: **dois estados opostos** ("ainda vai acontecer" e "não vai mais")
saíam da mesma cor no ponto do cartão, na legenda, no chip da Lista e no do drawer. É o HOM-002 em
miniatura: um sinal representando mais de uma coisa.

O protótipo já os separava (`statusMeta` [`:810`]): `muted` para agendado, `faint` para cancelado —
o de-ênfase de quem saiu da agenda. Agora `StatusMeta.tone` é **sempre** um token, e nenhum se
repete:

| agendado | confirmado | em atendimento | concluído | faltou | cancelado |
| --- | --- | --- | --- | --- | --- |
| `muted` | `info` | `teal` | `success` | `danger` | `faint` |

Duas consequências:

- **o `null` sumiu da tabela e sobrou onde significa outra coisa**: no `StatusSignal` da turma
  mista, em que o sinal deixa de ser a palavra e vira a composição ("1 de 4 concluídas") — ali a cor
  é neutra de propósito, porque pintar de verde um 1-de-4 é a mesma mentira, só que em cor. Nenhuma
  tela precisa mais traduzir "sem tom" para uma cor na hora de desenhar;
- **os chips passaram a usar a variante `-text` quando ela existe** (`var(--color-X-text, var(--color-X))`,
  a mesma expressão do badge do cartão): o teal sólido não tem contraste sobre 14% dele mesmo. Uma
  regra de cor, quatro superfícies.

### O cabeçalho: QUEM antes de QUÊ

Depois dos sete, o topo foi refeito (pedido com um desenho, e ele resolve um oitavo problema que a
lista não tinha nomeado). O cabeçalho era **só o chip de status** — a informação mais consultada do
painel, *para quem é esta sessão*, vivia 150px abaixo, dentro do cartão, com o mesmo peso do
telefone.

```
● Patrícia Gomes                                    ×
  Dr. Rafael Couto · CREFITO 3/098234-F

  [• Em atendimento]

  🕐 Horário   seg, 17/08 · 10:00–10:50 (50min)
  ─────────────────────────────────────────────
  ∿ Tipo       Sessão
  ─────────────────────────────────────────────
```

O que cada peça decide:

- **título = o paciente**, pela mesma regra do cartão do grid: na TURMA não existe "o paciente", e o
  título passa a ser o tipo ("Pilates") — e aí a linha `Tipo` do corpo sai, porque repetiria o
  título em 150px de painel;
- **legenda = profissional + registro**. O `crefito` já vem com o prefixo do cadastro
  ("CREFITO 3/…"), então não se monta rótulo aqui; sem registro, a legenda não deixa separador órfão;
- **o ponto é a cor do profissional** — a mesma da faixa lateral do bloco. É o que liga o painel à
  coluna de onde ele foi aberto;
- **o status desceu para o corpo**, onde continua sendo a primeira coisa lida. Ele não é
  identificação, é estado — e estado muda com o painel aberto (marcar presença rola o rollup);
- **o nome deixou de aparecer duas vezes**: na sessão individual o cartão perdeu a linha do nome (o
  selo de presença subiu para a linha do telefone). Na turma o nome fica em cada linha, porque ali
  ele identifica de quem é aquela presença, não o bloco;
- **o chip se cala quando o bloco já está resolvido**: `Appointment.status` é rollup das presenças
  (A2/D13), então num bloco terminal "Cancelado"/"Concluído"/"Faltou" no topo é a mesma frase que o
  selo da presença diz logo abaixo — e a presença é a FONTE (numa turma ela ainda diz por pessoa, o
  que o rollup nunca dirá). Enquanto não há desfecho é o contrário: o participante fica calado (o
  selo só existe a partir de "Previsto") e a fase do bloco é a única coisa que responde "como está
  isso?". O `ENCAIXE` sobrevive ao chip que sumiu — ele não é status, qualifica os dois casos;
- **cada linha fecha com um divisor**: sem ele, rótulo apagado e valor escuro em linhas
  consecutivas leem como uma tabela sem colunas — o traço é o que diz onde um fato termina e o
  outro começa. Inclusive na última, que separa a ficha do bloco do cartão do paciente logo abaixo;
- **dia e faixa de horário têm pesos diferentes** (o dia miúdo e apagado, a faixa em mono): emendados
  numa string mono só, a linha estourava os 404px e quebrava em duas — medido no browser.

Ficaram de fora, e por quê:

| # | Achado | Por que não agora |
| --- | --- | --- |
| 8 | H — colapsar participante resolvido na turma | mexe na UI de presença, que tem gotcha de clique ao vivo (`requestSubmit` no mesmo tick); merece fatia própria |
| 9 | Comunicação recolhida por padrão | `MessageTimeline` está sendo reescrita em paralelo (doc 65/72) — editar agora é colisão garantida |

**O WhatsApp no telefone** (o "e um atalho de WhatsApp" da recomendação E) também ficou de fora: o
envio ao paciente é do sistema (Zernio, doc 65), e um `wa.me` ao lado dele criaria dois caminhos com
regras diferentes de opt-out na mesma linha.

### O que **não** recomendo mexer

- **A caixa de pacote por participante.** Tentador juntar tudo numa seção só do bloco (como o
  protótipo). Não: o pacote é por presença (D11) e uma turma pode ter dois pacotes diferentes e um
  particular. Uma seção do bloco só funcionaria mentindo.
- **"Ajustar grade / horário" dentro do drawer** (o botão do protótipo, `:1897`). A massa por pacote
  reescreve N sessões numa transação; o lugar dela é a ficha, com a prévia. O drawer leva até lá
  pelo saldo — é o mesmo destino sem duplicar a operação perigosa em duas telas.
- **Mostrar `usadas` além de `restantes`.** "3 de 10" (a sessão) e "7 restantes" (o saldo) já
  fecham a conta; um terceiro número na mesma caixa é aritmética para o leitor fazer.

---

## 4. Testes

- **Backend** — `ApiWeb.AppointmentsControllerTest` ("sessão de pacote no bloco"): numeração
  cronológica com criação fora de ordem; avulsa não inventa pacote; **o pacote sobrevive à transição
  de presença** (o guard do `load` divergente); saldo e regra da falta no GET; e concluir a sessão
  **desconta o saldo na mesma resposta** — a prova de que `restantes` é derivado.
- `ApiWeb.AgendaJSONTest` (novo): a degradação quando os calculados não vêm carregados — porta
  lateral serializa sem pacote em vez de estourar `%Ash.NotLoaded{}`.
- **Web** — `packageBadge` e `packageDebit` em `agenda.test.ts` (regras puras, incluindo presença
  cancelada e pacote não punitivo); `AppointmentBlock.svelte.test.ts` (selo, ausência, rótulo
  acessível em bloco baixo); `AppointmentDrawer.svelte.test.ts` (frase, saldo, débito antes e
  depois, âncora da ficha, dois pacotes na mesma turma).
- **Drawer (doc 75)** — um teste por achado em `AppointmentDrawer.svelte.test.ts`: chip que não
  mente na turma mista, falta zero ausente, "1 falta" no singular, origem da fila, rótulo da
  observação, dia no horário (e "hoje" no dia corrente), `tel:`, e o cancelar que some/permanece.
- **Ao vivo** — pacote "Pacotao" (5 sessões, segundas) no dev: cartões de 03/08 a 31/08 numerando
  1/5 … 5/5; o drawer de 17/08 exibindo `seg, 17/08 · 10:00–10:50 (50min)`, telefone discável e
  `📦 Pacotao · 3 de 5` com "Falta debita 1 sessão deste pacote"; e o link caindo direto na seção
  Pacotes da ficha.
