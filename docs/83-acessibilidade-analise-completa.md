# 83 — Acessibilidade: a análise completa

**Data:** 2026-07-29 · **Escopo:** o app inteiro — 17 rotas internas, 2 diálogos, 2 estados
mobile, 5 páginas públicas, nos **dois temas** · **Relação com o doc 80:** aquela rodada (AN-08)
mediu só as páginas **públicas**, porque o login estava quebrado pelo pool `Swoosh.Finch` ausente
(doc 80 §4). Com aquilo consertado, esta rodada mede o que ficou de fora — e **fecha as 10
pendências** de lá: cada uma virou número, confirmação ou refutação (§8).

> **Estado: auditado e consertado.** O doc nasceu só com a análise — as decisões de paleta são
> humanas e ficaram para decisão. Elas foram tomadas no mesmo dia (§5), e então os 25 achados
> entraram em seis levas, cada uma com teste antes do conserto. **§11 é o placar**, com os números
> de depois e as três travas novas que impedem a volta. As seções 3–6 ficam como estão: são o
> registro do que foi encontrado, e é delas que os testes de regressão falam.

## 1. O que foi medido, e com quê

Quatro instrumentos, porque nenhum deles vê o que os outros veem:

| Instrumento | O que alcança | O que **não** alcança |
| --- | --- | --- |
| **axe-core no browser real** — `e2e/a11y-interno.spec.ts` (novo), `e2e/a11y-audit.spec.ts` (do AN-08) | regra de ARIA, contraste do que está **na tela**, título de documento, semântica | ordem de foco, aprisionamento, o que só existe no ponteiro |
| **sondas de teclado/foco/reflow** — `e2e/a11y-teclado.spec.ts` (novo) | Tabs até o conteúdo, escape do diálogo, reflow a 320/640px, axe no tema escuro | contraste de estado não renderizado |
| **sonda do upload** — `e2e/a11y-anexos.spec.ts` (novo) | se o input de arquivo está na ordem de tabulação | — |
| **razão de contraste sobre os tokens** — `scripts/contraste-tokens.mjs` (novo) | **todos** os pares do design system, inclusive os que o cenário semeado não põe na tela | se o par de fato aparece |

Todas rodam com a stack de pé e semeiam clínica/profissional/paciente/agendamento pela API, para as
telas medirem **cheias** — tela vazia não tem linha para reprovar.

Na rodada de auditoria as specs só **relatavam** (`expect(true)`), como a do AN-08: o D8 manda
auditar → consertar → só então barrar, já verde. Feitos os consertos, as duas de axe passaram a ser
**gate** (§9). As duas sondas (`a11y-teclado`, `a11y-anexos`) seguem relatando de propósito: o que
elas medem — quantos Tabs, onde o foco pousa — é diagnóstico, e virou asserção nos testes de
unidade dos componentes, que é onde uma regressão dessas aparece mais perto da causa.

## 2. O retrato em números

| Varredura | Estados | Violações | Nós | Regras distintas |
| --- | --- | --- | --- | --- |
| **Públicas** (`/`, `/entrar`, `/criar-conta`, `/privacidade`, `/termos`) | 5 | **0** | 0 | — |
| **Internas, tema claro** | 21 | 30 (todas `serious`) | **194** | 4 |
| **Internas, tema escuro** (amostra de 5) | 5 | 10 | 61 | 4 (as mesmas) |
| **Pares de token** (claro + escuro) | 76 pares | — | — | **36 reprovas** |

O contraste entre a primeira linha e as outras é a manchete: **o app público está em zero e o app
interno nunca foi medido**. Não é coincidência — é exatamente o recorte do doc 80.

As 4 regras das telas internas, por peso:

| Regra | Nós | Telas | O que é |
| --- | --- | --- | --- |
| `color-contrast` | 181 | 21 | §5 — e **86% disso é um token só** |
| `document-title` | 5 | 2 páginas | §3 ACC-02 |
| `aria-prohibited-attr` | 5 | 1 | §4 ACC-10 — ✅ **consertado** (2026-07-29) |
| `scrollable-region-focusable` | 3 | 2 | §4 ACC-09 |

## 3. Nível A — o teclado não chega

Estes três impedem a tarefa, não a dificultam. Todos **medidos**, não inspecionados.

### ACC-01 🔴 Não existe caminho de teclado para anexar arquivo (WCAG 2.1.1)

O input de arquivo de `PatientAttachments` é `class="hidden"` — `display:none`, que tira o
elemento **da ordem de tabulação inteira**, não só da tela. O único gatilho é a `<label>` da
drop-zone, e `<label>` não é focável. Medido no browser (`a11y-anexos.json`):

```json
{ "displayDoInput": "none", "classeDoInput": "hidden",
  "inputRenderizado": false, "labelDaZona": { "tabIndex": -1, "focavel": false } }
```

Quem usa teclado não anexa — nem por Tab, nem por Enter, nem por arraste (que é só ponteiro).
Isto **refuta a suposição do doc 80** (item 8: "já existe o input de arquivo; conferir a ordem"):
o input existe e não serve.

Conserto: o padrão visualmente-escondido-mas-focável (`sr-only`, não `hidden`), ou um `<button>`
de verdade que chame `input.click()`. Alvo: [`PatientAttachments.svelte:319-325`](../web/src/lib/components/patients/PatientAttachments.svelte#L319-L325).

### ACC-02 🔴 `/agenda` e `/relatorios` sem `<title>` (WCAG 2.4.2)

As duas únicas telas do app sem `<svelte:head><title>` — as outras 17 têm. axe reprova nos dois
temas; como o drawer e a gaveta mobile foram medidos **sobre a `/agenda`**, o mesmo defeito
aparece em 5 dos estados medidos. Efeito: a aba do browser e o histórico não dizem onde a pessoa
está, e o leitor de tela anuncia a navegação sem nome.

Conserto: duas linhas. Alvos: [`(app)/agenda/+page.svelte`](<../web/src/routes/(app)/agenda/+page.svelte>),
[`(app)/relatorios/+page.svelte`](<../web/src/routes/(app)/relatorios/+page.svelte>).

### ACC-03 🔴 Não existe caminho de teclado para **criar** agendamento (WCAG 2.1.1)

Os focáveis dentro do `<main>` da `/agenda`, medidos, são **oito — todos de navegação**:

```
Dia anterior · Hoje · Próximo dia · Dia · Semana · Mês · Lista · Entenda a agenda
```

Criar é clique na célula vazia (`div onclick`, suprimido com `svelte-ignore` em
[`DayGrid.svelte:412`](../web/src/lib/components/agenda/DayGrid.svelte#L412)) ou arraste, que é só
ponteiro. Confirma o item 5 do doc 80, agora com a lista na mão.

Nuance que vale registrar: os **blocos existentes são `<button>`** — abrir, ver e editar têm
caminho de teclado (a sonda pegou o foco voltando para "09:00 · Marina Prado · Sessão ·
Agendado"). O buraco é só a criação. A proposta barata do doc 80 continua válida: um botão "Novo
agendamento" no `AgendaNav`, abrindo o mesmo modal sem preset de hora.

## 4. Nível AA — o que degrada em silêncio

### ACC-04 🟠 Erro de formulário **invisível no mobile** e nunca anunciado (3.3.1 / 4.1.3)

Nas duas fichas maiores do app, a mensagem de erro é `class="hidden … md:flex"`:

- [`PatientForm.svelte:721`](../web/src/lib/components/patients/PatientForm.svelte#L721)
- [`ProfessionalForm.svelte:700`](../web/src/lib/components/professionals/ProfessionalForm.svelte#L700)

Abaixo de `md` o lugar dela é um `<div class="flex-1 md:hidden">` **vazio**: o 422 do servidor
("CPF já cadastrado", "telefone inválido") não aparece em lugar nenhum — a pessoa clica em salvar
no celular e nada acontece, sem explicação. E em **nenhuma** largura a mensagem é live region,
então o leitor de tela também não a recebe quando ela surge.

Os modais (`TypeModal:146`, `MemberModal:133`, `ExceptionForm:112`) mostram o erro num `<p>`
visível em qualquer largura — mas igualmente sem live region. Quem faz certo é o
[`AuthForm.svelte:128`](../web/src/lib/components/AuthForm.svelte#L128), com `role="alert"`: o
padrão certo já existe no repo, só não chegou às telas de dentro.

Relacionado: **nenhum erro é associado ao campo que o causou**. `aria-invalid`/`aria-describedby`
aparecem em apenas 3 lugares (`PeriodEditor`, CNPJ da clínica, horas da comunicação); o resto
descreve o problema em prosa no rodapé, longe do input.

### ACC-05 🟠 O toast cria a live region junto com o conteúdo (4.1.3)

[`Toast.svelte:16-21`](../web/src/lib/components/Toast.svelte#L16-L21): o `{#if active}` embrulha o próprio
elemento `role="status"`. Uma região que **nasce preenchida** costuma não ser anunciada — o leitor
de tela precisa da região presente e vazia para notar a mudança. Como o toast é o feedback
principal de salvar/excluir/arquivar do app inteiro, o efeito prático é que quase nenhuma
confirmação de ação é audível.

Conserto: manter o wrapper com `role="status"` sempre montado e trocar só o conteúdo.

### ACC-06 🟠 Nada anuncia o tempo real (4.1.3)

Notificação nova muda o badge do sino; a agenda troca blocos por WebSocket. Não há `aria-live` em
nenhum dos dois caminhos (`realtime.ts`, `Rail.svelte`, `(app)/+layout.svelte`). Para quem não vê
a tela, o app é estático.

### ACC-07 🟠 O foco escapa do diálogo aberto (2.4.3 / 2.1.2)

Medido: com o drawer do agendamento aberto, o **7º Tab** leva o foco para o `body` — a tela de
trás. Os dois consertos do AN-08 seguram (verificados ao vivo: o foco **entra** no painel ao
abrir, com o nome certo, e **volta** ao bloco ao fechar); o que falta é o passo 2 de 2, o
aprisionamento. Também não há `inert`/`aria-hidden` no fundo enquanto o diálogo vive.

O que **não** é problema, e a sonda esclareceu: o fundo não rola (`scrollY` 0→0). O shell é
`h-dvh` com rolagem interna, então a falta de scroll-lock não tem efeito.

### ACC-08 🟠 A gaveta de navegação mobile não gerencia foco nenhum

Ela é escrita à mão em [`(app)/+layout.svelte:103-115`](<../web/src/routes/(app)/+layout.svelte#L103-L115>)
e **não usa o shell `Drawer`** — por isso não herdou os consertos do AN-08. Medido a 390px: ao
abrir, o foco fica no hambúrguer; **1 Tab vai para o avatar do topbar**, ou seja, para o fundo, não
para dentro da gaveta. Falta ainda `role="dialog"`/`aria-modal` no painel e
`aria-expanded`/`aria-controls` no hambúrguer ([`Topbar.svelte:21-28`](../web/src/lib/components/shell/Topbar.svelte#L21-L28)).

### ACC-09 🟠 Regiões que rolam sem receber foco (`scrollable-region-focusable`)

3 nós: a grade da agenda (`div.overflow-auto` do `DayGrid`) e o `<main>` de `/relatorios`. Rolam,
mas nenhum elemento focável dentro alcança o conteúdo rolado — o teclado não rola a agenda.

### ACC-10 ✅ A fórmula do KPI não chegava a teclado, a leitor de tela nem ao celular (`aria-prohibited-attr`)

5 nós em `/relatorios`: `aria-label` num `<span>` sem role — **atributo proibido**, ignorado pelas
tecnologias assistivas. A outra metade da afordância é `title={formula}` numa `<div>` não focável,
que é hover de mouse. Resultado: a explicação que o HOM-021 pediu de propósito ("o número aparecia
sem a conta que o produz") existe só para quem usa mouse e vê a tela.

**O celular é o caso que fecha o argumento**, e ele não é hipotético: no toque **não existe hover**,
então quem abre o relatório no telefone — que é justamente quem cobra o número em reunião — voltava
a ver um número sem a conta. Não havia caminho nenhum até a fórmula.

**Consertado em 2026-07-29** ([`relatorios/+page.svelte`](<../web/src/routes/(app)/relatorios/+page.svelte>)):
o ícone virou `<button>` de 24px (WCAG 2.5.8) com `aria-label="Como {label} é calculado"` e
`aria-haspopup="dialog"`, e o clique abre o [`Modal`](../web/src/lib/components/Modal.svelte) com a
fórmula. O `Modal` já resolve foco-ao-abrir/devolver (AN-08), `Esc` e clique-fora, e já é o que o
app usa em tela pequena — em vez de `aria-describedby` num tooltip próprio, que teria de reimplementar
posicionamento e dispensa em telas de 390px. O `title` do cartão fica, porque o hover do mouse
continua sendo o caminho mais rápido para quem tem mouse.

Guardado por 4 testes em
[`page.svelte.test.ts`](<../web/src/routes/(app)/relatorios/page.svelte.test.ts>), um deles
afirmando `tagName === 'BUTTON'` — a regressão do ACC-10 em si, porque voltar para `<span>` não
quebraria nenhuma das asserções sobre o texto da fórmula.

### ACC-11 🟠 O anel de foco é invisível no tema claro (1.4.11)

O indicador de foco de **todo o app** é `outline: 2px solid var(--mv-teal-solid)`
([`app.css:251`](../web/src/lib/styles/app.css#L251)). Medido contra as três superfícies do tema
claro, com piso 3:1:

| Anel sobre | Razão | Piso |
| --- | --- | --- |
| `surface` `#ffffff` | **2,57** | 3 |
| `canvas` `#fbfcfd` | **2,50** | 3 |
| `surface2` `#f6f8f9` | **2,41** | 3 |

No tema escuro passa com folga (6,44–7,58). Ou seja: **quem navega por teclado no tema claro
quase não vê onde está** — o que agrava todos os achados acima. Candidato medido pelo pior caso
(`surface2`): `#00a192` (3,03); alternativa mais robusta é anel duplo (teal + traço escuro), que
não depende da superfície.

Na mesma família, e por isso junto: as bordas de input (`bs` **1,24** / `bd` **1,51** sobre
`surface`) ficam abaixo dos 3:1 de 1.4.11. Aqui a borda **é** a única pista de que existe um
campo (o input tem `bg-surface`, igual ao card), então o critério se aplica. Candidato para a
borda densa: `#8f959b` (3,03).

## 5. Decisões de paleta

`color-contrast` são 181 dos 194 nós, e **quase tudo é um token só**. Isto mexe no app inteiro e a
AN-01 acabou de calibrar essas telas a olho, então a decisão é humana — como no doc 80.

> **Decidido em 2026-07-29** e aplicado: escurecer os tokens de texto (não migrar os 239 usos) e
> **virar o texto para escuro** sobre as cores sólidas, em vez de escurecer quatro cores de marca —
> `danger` é a exceção que escureceu para manter o branco. A tabela abaixo é o diagnóstico; os
> valores que de fato entraram estão em §11, e diferem dos "candidatos" daqui por um motivo que só
> apareceu depois: **as tintas** (§11.2).

| # | Par | Medido | Nós / telas | Candidato medido |
| --- | --- | --- | --- | --- |
| ACC-12 🔴 | `faint` `#8a929b` sobre branco, 10,5px **bold** | **3,15:1** | **150 / 18** | claro `#6b737c` (4,51) |
| | idem, 12px normal | 3,15:1 | 5 / 1 | idem |
| | `faint` `#6b747d` sobre `surface`, tema escuro | **3,74:1** (3,48 sobre `surface2`) | 61 nós na amostra | escuro `#7e8790` (4,53) |
| ACC-13 🟡 | `teal_text` `#0a7e73` sobre `teal_subtle` | **4,46:1** | 26 / 2 | `#097d72` (4,52) |

O `faint` sozinho é **86% de todo o contraste reprovado** do app. As duas saídas continuam as do
doc 80: escurecer o token, ou reclassificá-lo como "só para ≥18px/14px-bold" e migrar os usos
pequenos para `muted` (que passa: 5,49–6,95).

Os pares abaixo **o axe não viu** — o cenário semeado não põe esses estados na tela —, mas estão
no design system e vão aparecer em produção. Medidos pelos tokens:

| # | Par | Claro/escuro | Candidato escuro (fundo) | Candidato texto escuro |
| --- | --- | --- | --- | --- |
| ACC-14 🔴 | branco sobre `teal_solid` (botão teal, chip ABRIU) | **2,57** | `#008576` (4,55) | `ink` dá **6,81** |
| ACC-15 🟡 | branco sobre `success` (badge) | **3,29** | `#148847` (4,52) | `ink` dá 5,31 |
| ACC-16 🟡 | branco sobre `info` (badge) | **3,76** | `#1c70f0` (4,54) | `ink` dá 4,65 |
| ACC-17 🟡 | branco sobre `danger` (badge, `PriorityBadge`) | **3,91** | `#d83b40` (4,55) | `ink` dá 4,47 — **reprova por um fio** |
| — | branco sobre `warning` | 2,03 | — | **já consertado** (ENCAIXE usa `ink` fixo: 8,63) |
| ACC-18 🟡 | branco sobre `sage` (gradiente de landing/aside) | **2,71** | — | — |

> O `danger` é o único onde a receita do ENCAIXE (trocar para texto escuro) **não** resolve:
> 4,47 contra piso 4,5. Ali o fundo precisa escurecer.

### ACC-19 🟠 O número do KPI de relatórios pintado em `warning` mede 2,03:1

Caso concreto da mesma família, e o pior do app: os KPIs de `/relatorios` pintam o número em
`23px font-semibold` com a cor semântica direto sobre `surface`. 23px fica **abaixo** dos 24px de
"texto grande", então o piso é 4,5 — e mesmo com o piso 3 de texto grande, `warning` reprovaria:

| Cor do número (23px) | Claro | Escuro |
| --- | --- | --- |
| `warning` (taxa de falta ≤20%) | **2,03** | 8,77 |
| `teal_solid` | **2,57** | 6,92 |
| `success` (concluídos) | **3,29** | 5,40 |
| `info` | **3,76** | 4,72 |
| `danger` (taxa de falta >20%) | **3,91** | 4,54 |

Ninguém tinha medido porque a `/relatorios` nunca entrou numa varredura. No tema escuro está tudo
certo — o problema é só o claro.

## 6. Menores

- **ACC-20 🟡 13 Tabs até o conteúdo, sem skip link.** Medido na `/agenda`. A landing **tem**
  (`.cn-skip` em `cinetra.css:59`); o app não. Confirma o item 7 do doc 80, agora com número.
- **ACC-21 🟡 Combobox de paciente incompleto.** `PatientPicker` declara `role="combobox"` +
  `aria-controls`, mas o popup é um `<ul>` sem `role="listbox"`, os itens não são `option`, não há
  `aria-activedescendant` e **não há nenhum `onkeydown`** — seta para baixo não navega. É operável
  (Tab alcança os botões), mas não faz o que o `role` promete.
- **ACC-22 🟡 Hierarquia de headings quase ausente.** O `<h1>` vem do `Topbar` (título da seção);
  3 telas acrescentam um **segundo** `<h1>` (`/auditoria`, `/notificacoes`, `/perfil`), e **9 das
  19** não têm nenhum heading além do do cromo — contando os componentes que cada página renderiza:
  agenda, fila, as duas listas, a ficha do profissional, relatórios e os três formulários. A
  exceção entre as que não têm heading no próprio arquivo é a **ficha do paciente**, que ganha
  quatro dos componentes (histórico, próximas, anexos, pacotes). Navegar por headings, que é como
  leitor de tela varre página, praticamente não funciona.
- **ACC-23 🟡 Informação só no hover.** Da lista que levantei, **dois casos não eram defeito** e a
  verificação de perto os retirou — fica registrado porque o erro é fácil de repetir:
  - `FieldDiff` (`<del>`/`<ins>`): o `truncate` do Tailwind é **só CSS** — o texto inteiro está no
    DOM e o leitor de tela o lê completo. O `title` ali é conveniência de mouse, não a única via;
  - `DayGrid` (ocupação da coluna): a barra é um `OccupancyBar` com `role="meter"` e
    `aria-label`/`aria-valuenow` — o número chega por ARIA, não só pelo `title`.

  Sobrou **um** caso real: `AuditEntry` mostrava só a HORA e guardava a data completa no `title`.
  Numa trilha de auditoria, "14:32" sem dia não localiza nada, e o `datetime` é para máquina, não
  para voz. O KPI de relatórios era o quarto, e já foi (§ACC-10).
- **ACC-24 ⚪ `<aside>` da sidebar sem rótulo** — dois landmarks de navegação, um deles anônimo.
- **ACC-25 ⚪ Primeiro ponto de tabulação nomeado só por `title`.** A marca do rail
  ([`Rail.svelte:58-60`](../web/src/lib/components/shell/Rail.svelte#L58-L60)) é
  `<a href="/" title="Cinetra">` com o símbolo `aria-hidden`: o nome sai do
  `title`, que é mecanismo de último recurso. (E o destino é a **landing**, não o app — isso é UX,
  não a11y.)
- **ACC-26 ⚪ `autofocus` no renomear anexo** — aceitável: é foco em formulário que a pessoa
  acabou de abrir por ação, não no carregamento da página. Fica registrado porque está suprimido
  com `svelte-ignore`.

## 7. O que está certo — confirmado, não presumido

Vale listar porque metade disto o doc 80 só pôde afirmar por inspeção:

- **Páginas públicas em zero** violações axe (5 páginas, WCAG 2.0/2.1 A+AA). Os consertos do AN-08
  seguram.
- **Reflow limpo**: a 320px (≡400% de zoom) e a 640px (≡200%), `/agenda`, `/pacientes` e
  `/relatorios` **não** têm rolagem horizontal de documento. Fecha a metade "zoom 200%" do item 9
  do doc 80.
- **Foco entra no diálogo e volta ao gatilho** — os consertos do AN-08 verificados ao vivo, não só
  em teste de unidade.
- **Blocos da agenda são `<button>`**: abrir/ver/editar agendamento tem caminho de teclado.
- **`aria-current` em toda a navegação** (rail, sidebar, abas de visão, datas) — 17 usos.
- **Nenhum `button-name`/`link-name` reprovado** em 21 estados: os botões ícone-só têm
  `aria-label`.
- **Ícones lucide saem `aria-hidden="true"` por padrão** (verificado no `Icon.svelte` do pacote:
  só perdem o atributo quando recebem prop de a11y) — nenhum ruído de "graphic" no leitor.
- **`lang="pt-BR"`** estampado no SSR; tema escuro sem flash.
- **`prefers-reduced-motion` respeitado** globalmente (`app.css:265`).
- **`Field` associa rótulo** por `<label>` envolvente, e usa `role="group"` para grupos de botões —
  a distinção certa, documentada no próprio componente.
- **Matriz de acessos** é `<table>` de verdade, com `scope="col"`/`scope="row"`.
- **Nenhum `tabindex` positivo** no repo (nada reordena a tabulação à força).
- `<main>`, `<header>`, `<nav aria-label="Navegação principal">` presentes.

## 8. As 10 pendências do doc 80, uma a uma

| Item do doc 80 | Desfecho aqui |
| --- | --- |
| 1. `faint` reprova | **Confirmado e quantificado**: 155 nós, 18 telas, 86% de todo o contraste reprovado → ACC-12. **Decidido e consertado** (§11) |
| 2. branco sobre `teal_solid` 2,57 | Confirmado pelo token; o axe não o viu (estado ausente do cenário) → ACC-14 |
| 3. badges brancas sobre `danger`/`success`/`info` | Confirmado pelo token → ACC-15/16/17. **`danger` não aceita a receita do ENCAIXE** (4,47) |
| 4. `teal_text` sobre `teal_subtle` 4,46 | **Confirmado pelo axe**: 26 nós em 2 telas → ACC-13 |
| 5. agenda sem teclado para criar | **Confirmado com a lista medida** dos 8 focáveis → ACC-03 |
| 6. focus trap incompleto | **Medido**: escapa no 7º Tab → ACC-07 |
| 7. skip link ausente | **Medido**: 13 Tabs até o `<main>` → ACC-20 |
| 8. drop-zone de anexo + `autofocus` | **Refutada a premissa**: o input existe mas é `display:none` — não há caminho de teclado nenhum → ACC-01 (nível A). O `autofocus` é aceitável → ACC-26 |
| 9. zoom 200% e páginas internas no axe | **Feito**: 21 estados internos no claro + 5 no escuro; reflow limpo a 320/640px |
| 10. o gate (D8) | **Ligado, completo e verde** — §9 |

Ou seja: as 10 estão fechadas, e as três que eram decisão de paleta (1, 2, 3) deixaram de ser
pendência porque a decisão foi tomada (§5) e aplicada (§11).

E o que o doc 80 **não** podia ter visto, porque não media as telas internas: ACC-02 (`<title>`),
ACC-04 (erro invisível no mobile), ACC-05 (toast), ACC-06 (tempo real), ACC-08 (gaveta mobile),
ACC-09, ACC-10, ACC-11 (anel de foco), ACC-19 (KPI), ACC-21, ACC-22.

## 9. O gate (D8): LIGADO, e sem quarentena

A proposta original aqui era um gate em dois níveis, com `color-contrast` em quarentena até a
paleta ser decidida. **Não foi preciso**: a paleta foi decidida no mesmo dia, e as duas varreduras
chegaram a zero — então o gate nasceu completo, que é exatamente o que o D8 pede (auditar →
consertar → barrar já verde).

- `e2e/a11y-audit.spec.ts` → **barra** as 5 páginas públicas;
- `e2e/a11y-interno.spec.ts` → **barra** as 21 telas/estados internos, todas as regras.

A mensagem da falha traz `regra @ tela (N×) — alvo`, não só um número, para dizer onde olhar; o
JSON completo continua sendo escrito para diagnóstico. Vale aqui a regra do gate de cobertura
([`.claude/rules/testes.md`](../.claude/rules/testes.md)): **baixar o gate é decisão humana
explícita**, nunca atalho para verde.

Os e2e **não rodam no CI** (decisão de 2026-07-27: precisam da stack inteira), então "gate" é o
comando local que precede o PR. Levá-lo ao CI é decisão separada — e agora barata, porque o
trabalho todo é rodar `docker compose up` antes.

## 10. Como reproduzir

Com a stack de pé (`docker compose up`) e **sem `RESEND_API_KEY`** no `.env` — com a chave, o
mailer real assume, `/dev/mailbox` fica vazio e os cenários autenticados quebram por timeout
(doc 80 §4):

```bash
# o Playwright faz build+preview sozinho; se o build passar de 120s, suba o preview antes
# (npm run build && npm run preview -- --port 4173) que ele reaproveita
docker compose exec web npm run test:e2e -- a11y-audit.spec.ts     # públicas → a11y-report.json
docker compose exec web npm run test:e2e -- a11y-interno.spec.ts  # internas → a11y-report-interno.json
docker compose exec web npm run test:e2e -- a11y-teclado.spec.ts  # teclado/foco/reflow/escuro
docker compose exec web npm run test:e2e -- a11y-anexos.spec.ts   # o upload por teclado

# os pares do design system — não precisa de stack nem de browser
docker compose exec web node scripts/contraste-tokens.mjs
```

Os quatro `.json` são artefatos de auditoria e estão no `.gitignore` — o conteúdo mora aqui. O
`contraste-tokens.mjs` imprime a tabela em Markdown, pronta para colar num doc como os de §5; ele
copia os hex do `app.css` **à mão**, de propósito, para que mexer num token e não rodar o script
apareça no diff.

**A ordem em que foram consertados** (§11): ACC-01/02/03 (nível A, impedem tarefa) → ACC-11 (o anel
de foco agrava todo o resto) → ACC-04/05/06 (feedback que não chega) → ACC-12 (a decisão de paleta
que vale 86% do contraste) → o resto.

## 11. O conserto

### 11.1 O placar

| Medida | Antes | Depois |
| --- | --- | --- |
| axe, páginas públicas | 0 | **0** (agora com gate) |
| axe, telas internas (21 estados, claro) | 30 violações · 194 nós | **0** |
| axe, telas internas (5 telas, escuro) | 10 violações · 61 nós | **0** |
| Pares de token reprovando | 36 de 76 | **0** (32 asserções no tripwire) |
| Tabs até o conteúdo na `/agenda` | 13 | **1** (skip link) |
| Focáveis no `<main>` da `/agenda` | 8, nenhum cria | **10**, com "Novo agendamento" e a grade |
| Foco escapa do diálogo | no 7º Tab | **não escapa** (40 Tabs) |
| Foco ao abrir a gaveta mobile | ficava no hambúrguer | **entra no diálogo** |
| Caminho de teclado para anexar | nenhum | input `sr-only` focável |
| Suíte do `web/` | 2 222 testes | **2 251**, 0 falhas · cobertura 92,9% |

Os 25 achados foram todos endereçados; nenhum ficou aberto. ACC-26 (o `autofocus` do renomear) era
"aceitável, fica registrado" e continua assim — é foco em formulário que a pessoa acabou de abrir.

### 11.2 A lição que só apareceu consertando: as tintas

A decisão de §5 escureceu os tokens de texto pelo **pior fundo que eu havia medido** — as três
superfícies (branco, `surface2`, `canvas`). Depois de aplicar, o axe voltou com 5 violações, e uma
delas era o chip ENCAIXE da legenda em **4,19**: um âmbar que passava folgado sobre branco reprovava
sobre `color-mix(warning 12%)`, porque **o app pinta callout e chip com uma tinta da própria cor do
texto** (`bg-<sem>/10..14`) — e ali o fundo já está tingido daquilo que se quer ler.

O tripwire então passou a medir a tinta de 14% (o maior tom em uso) além das superfícies, e
**achou mais quatro** que o axe não tinha visto, porque aqueles estados não estavam em nenhuma tela
do cenário semeado. Foi isso que empurrou os valores finais para além do mínimo óbvio:

| Token de texto | Candidato de §5 (só superfície) | **Valor final** (superfície + tinta) |
| --- | --- | --- |
| `--mv-faint` claro / escuro | `#6b737c` / `#7e8790` | mantidos (não recebem tinta) |
| `--mv-success` claro | `#148847` | `#037736` |
| `--mv-warning` claro | `#ab5c00` | `#a15200` |
| `--mv-danger` claro | `#d13439` | `#c3262b` |
| `--mv-info` claro | `#166aea` | `#0b5fdf` |
| `--mv-danger` / `--mv-info` escuro | `#ed5055` / `#3084ff` | `#f5585d` / `#3c90ff` |

Corolário no espírito do doc 35 ("meça pelo caminho da app"): **o axe mede o que está na tela do
cenário; o tripwire mede o design system.** Nenhum dos dois substitui o outro — o axe achou a tinta
que eu não tinha pensado, e o tripwire achou os quatro estados que o axe nunca renderizou.

### 11.3 O desenho que saiu disso: fundo e texto são tokens diferentes

O achado estrutural da paleta não era "faltou contraste", era **um token servindo a dois papéis**:
as mesmas quatro cores semânticas pintavam fundo de badge *e* texto de aviso. Como texto no tema
claro chegavam a 2,03 (`warning`, 23 usos); escurecê-las para servir de texto apagaria as badges.

Então cada semântica virou um par, que é o que o teal já era (`--mv-teal-solid` + `--mv-teal-text`):

- `--mv-<sem>-solid` — **fundo**, fixo nos dois temas (badge é badge), com `--mv-on-solid` (texto
  escuro) por cima. `danger-solid` é a exceção: escureceu para `#d83b40` e **manteve o branco**,
  porque botão destrutivo com texto escuro sobre vermelho claro perde a força de aviso;
- `--mv-<sem>` — **texto/ícone**, por tema. Os 91 usos de `text-danger` e parentes não mudaram uma
  linha; quem mudou de nome foram os ~5 fundos sólidos (`bg-warning` → `bg-warning-solid`).

E as **paletas categóricas** (avatar, tipo de atendimento, prioridade) não são tokens de tema:
vinham de lista, com `text-white` cravado em ~20 telas. Medido: **5 das 7 cores de avatar reprovam
com branco** (`#E69F00` em 2,25) e não existe uma cor de texto única que sirva às sete. Escurecer a
lista não é opção — ela é contrato com o `one_of` do servidor (débito D-3). A saída foi escolher o
texto **por cor de fundo**: `textoSobre()` em [`$lib/contraste.ts`](../web/src/lib/contraste.ts) e
`avatarStyle()`, que devolve fundo **e** cor juntos, justamente para não existir chamada que
esqueça uma das metades. O tripwire das paletas reprovou exatamente um caso — `urgente #E5484D`,
onde **nenhuma** das duas cores de texto alcançava 4,5 —, e por isso a prioridade urgente virou
`#D83B40`, o mesmo vermelho do `danger-solid`.

### 11.4 As três travas novas

Consertar sem trava é adiar. As três rodam sem browser (as duas primeiras) ou com a stack de pé:

| Trava | O que fixa | Onde |
| --- | --- | --- |
| `styles/contraste.test.ts` | 32 asserções sobre o `app.css`: texto nas 3 superfícies **e** na tinta 14%, fundo sólido + `on-solid`, e o anel de foco em toda superfície — inclusive o rail | `web/src/lib/styles/` |
| `contraste.test.ts` | as 3 paletas categóricas: para toda cor, `textoSobre()` tem de alcançar 4,5 — cor nova que não sirva a nenhum texto reprova aqui | `web/src/lib/` |
| gate do axe (§9) | as 26 telas/estados, todas as regras WCAG 2.0/2.1 A+AA | `web/e2e/a11y-*.spec.ts` |

Dois detalhes dos testes que valem para quem escrever o próximo:

- **o tripwire lê o CSS**, não repete os hex. Um teste que carrega os valores à mão concorda com o
  CSS até o dia em que divergem — e aí fica verde sobre uma paleta que mudou;
- **o primeiro `contraste.test.ts` passou sobre um app quebrado.** A asserção do anel de foco media
  os tokens (`max(teal, text) ≥ 3`) e não a regra CSS, que emitia só o teal. Verde, foco invisível.
  Hoje o teste também lê a regra `:focus-visible` e exige que ela cite os dois anéis.

### 11.5 Duas armadilhas de medição que custaram tempo

Ficam aqui porque as duas produzem **teste verde sobre app quebrado**, ou o contrário:

1. **`offsetWidth` é sempre 0 no jsdom.** O filtro de "elemento visível" do focus trap começou
   medindo caixa renderizada — o jeito óbvio. No jsdom isso zera a lista inteira, o trap manda o
   foco para o painel e o teste concorda. A pergunta certa é `checkVisibility()` (que considera
   ancestrais), com `getComputedStyle` de retaguarda, e foi preciso **medir o que o jsdom oferece**
   antes de escolher — ver [`$lib/dialogo.ts`](../web/src/lib/dialogo.ts).
2. **o axe lê cor composta no meio da animação.** Varrendo um diálogo enquanto o `animate-scale`
   ainda corre (`opacity: 0 → 1`), um rótulo `text-muted` sobre `bg-surface` foi medido como
   `#7f868e` sobre `#e4e4e4` — cores que não existem na paleta. Eram três "violações" que sumiram
   ao esperar `document.getAnimations()` terminar. Se um dia o axe acusar contraste com hex que você
   não reconhece, suspeite disto antes de mexer no token.

### 11.6 O que fica anotado, sem conserto

- **`/perfil` tem dois `<h1>`**, e o do topbar diz "Cinetra". A causa é que `perfil` não é seção de
  navegação (`sectionOf` devolve `null`), então o cromo cai no nome do produto. Não é violação (o
  axe não reprova `<h1>` repetido) e consertar bem significa dar seção a `/perfil` no `nav.ts` — o
  que mexe no rail e na sidebar, fora do escopo de a11y. Fica como follow-up de UX.
- **O `PARSE_ERROR` do `npm run coverage`** é ruído pré-existente do remapeador do v8 com arquivos
  `.svelte.ts` (o repo já tinha três antes desta leva). O gate passa; não é regressão daqui.
