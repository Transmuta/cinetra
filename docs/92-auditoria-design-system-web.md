# 92 — Auditoria de consistência do design system do `web/`

**Data:** 2026-07-30 · **Escopo:** `web/src/` inteiro — 96 arquivos `.svelte` (16.878 linhas), os
dois arquivos de token (`app.css` 396, `cinetra.css` 495), os 24 specs de `e2e/` e os 76
`*.svelte.test.ts` · **Natureza:** só análise. **Nada foi mudado.**

**Relação com os docs anteriores.** O [83](83-acessibilidade-analise-completa.md) mediu
*acessibilidade* e consertou 25 achados; a [ADR-020/021](00-decisoes.md) trocou a paleta. Este doc
mede outra coisa: **se o app fala uma língua só**. É a pergunta que o 83 não fez — lá o critério
era "passa 4,5:1", aqui é "o mesmo papel visual sai igual em toda tela".

**Método.** Contagem, não impressão. Toda linha abaixo veio de `rg` sobre `web/src` ou de sonda
executada: razão de contraste calculada em Node sobre os hex do `app.css`, e o
`<input type="date">` fotografado em Chromium real com e sem `color-scheme`. Onde não medi, digo
que não medi.

**Manchete.** A camada de *cor* é exemplar e está travada por teste. A camada de **dimensão**
(tamanho de fonte, raio, z-index, espaçamento do controle) não existe — não há escala, e o app
paga isso com 1.014 utilitários arbitrários. Fora disso, três achados de alta severidade, todos
invisíveis para os gates atuais **por construção**, não por descuido.

---

## 1. O retrato em números

| Dimensão | Medida | Leitura |
| --- | --- | --- |
| Tokens `--mv-*` definidos | 44 | |
| Tokens expostos como utilitário (`@theme inline`) | 29 cores + 7 sombras + 4 raios | |
| Tokens **sem nenhum uso** no `src/` | **4** | §4.3 |
| Hex/`rgba()` crus em `.svelte` do **app interno** (fora de comentário) | **5 ocorrências**, 3 valores | ótimo — §4.2 |
| Literais `white`/`black` do Tailwind no app interno | 21, quase todos legítimos (rail escuro nos dois temas) | §4.2 |
| Cores literais em `.svelte` de **landing/auth** | 203 hex + 34 `rgba()` | deliberado (paleta `cn-`) |
| Variantes `dark:` no código | **0** | ótimo — §2 |
| Utilitários com valor arbitrário `-[…]` | **1.014** | §3.M-1 |
| ├ `text-[Npx]` | 658, em **22 valores distintos** | 261 deles em meio-pixel |
| ├ `rounded-[…]` | 97, em 11 valores | §3.M-2 |
| └ resto (size, h, max-w, py, tracking…) | 259 | |
| Usos da escala tipográfica do Tailwind (`text-sm`…) | **15** | contra 658 arbitrários |
| Sintaxe Svelte 4 remanescente (`export let`, `on:`, `<slot>`, stores) | **0** | ótimo — §2 |
| Runes | 87 `$state` · 317 `$derived` · 32 `$effect` · 91 `$props` | |
| `<button>` cru | **129** | contra **1** uso de `<Button>` |
| `<input>` cru | 156 | contra 29 usos de `<Field>` |
| Blocos `<style>` em `.svelte` | **0** | ótimo — §2 |
| `:global(` | **0** | ótimo |
| Componentes com `.svelte.test.ts` ao lado | **58 de 65** | §3.B-10 |

---

## 2. O que está sólido — e por quê

Isto não é cortesia. São quatro decisões que **removeram classes inteiras de erro** e que quem
mexer no `web/` deve preservar.

### 2.1 A cor é token, e o token é medido

Zero variantes `dark:` no código inteiro. O tema escuro não é uma segunda folha de estilo: é a
mesma folha lendo custom properties trocadas por `[data-theme]`. A consequência prática é que
**não existe a categoria de bug "componente novo esqueceu o dark mode"** — o desenvolvedor teria
de sair do caminho para escrever uma cor que quebra.

Dentro do app interno restam **5** hex/`rgba()` crus, em 3 valores distintos: `#0072B2` (2×,
vira o achado M-8), `#9a6a05` (1×, vira M-9) e `rgba(8,10,12,0.42)` do overlay (2×, vira B-6).
Os 21 usos de `white`/`black` do Tailwind são quase todos legítimos — o rail é escuro nos **dois**
temas, então `text-white/60` ali é a cor certa, não um vazamento. As exceções estão em §4.2.

O tripwire é [`contraste.test.ts`](../web/src/lib/styles/contraste.test.ts), que **lê o
`app.css`** em vez de repetir os hex — a única forma de um teste de paleta não divergir da paleta.
Ele roda no CI por `npm run coverage`. O [`contraste-tokens.mjs`](../web/scripts/contraste-tokens.mjs)
é o diagnóstico manual ao lado; a divisão está escrita no cabeçalho do teste e está correta.

### 2.2 Svelte 5 sem resquício

`export let`: 0. `on:click`: 0. `<slot>`: 0. `$$props`/`$$restProps`: 0.
`createEventDispatcher`: 0. `svelte/store`: 0. `$app/stores` (depreciado): 0 — e 22 usos de
`$app/state`, que é o substituto. 50 `{#snippet}` e 133 `{@render}`.

Não é "quase migrado". É **migrado**. Numa base de 96 componentes isso é raro e não deve ser
tratado como dado.

### 2.3 O diálogo tem contrato, e o contrato é o mesmo nos três lugares

`Modal`, `Drawer` e a gaveta mobile do `+layout.svelte` implementam **a mesma tríade**: mover o
foco ao abrir, devolvê-lo ao gatilho ao fechar (`document.activeElement` guardado no `$effect`,
restaurado no teardown), e aprisionar o Tab por `aprisionarTab` de
[`$lib/dialogo`](../web/src/lib/dialogo.ts). `ConfirmDialog` **compõe** `Modal` em vez de
reimplementá-lo ([`ConfirmDialog.svelte:29`](../web/src/lib/components/ConfirmDialog.svelte)).

Há exatamente uma exceção, e ela é o achado A-3.

### 2.4 A lógica mora em `lib/*.ts`, e é testada

`Sidebar.svelte` tem 596 linhas e importa `sectionOf`, `actionOptions`, `countByStatus`,
`canManagePatients`, `parsePeriod`… — **12 módulos de lógica**. Nenhuma regra de negócio no
componente. Há **37 `*.test.ts` na raiz de `src/lib/`** e gate de cobertura em 80%
([`vite.config.ts:100`](../web/vite.config.ts)).

### 2.5 O gate de a11y é gate de verdade

[`a11y-interno.spec.ts`](../web/e2e/a11y-interno.spec.ts) varre 17 rotas + 2 diálogos + 2 estados
mobile com axe e **falha o build**. Tem uma única isenção (`semExcecaoDoPrimario`), com escopo
estreito, motivo escrito e condição de remoção. É o desenho certo: um gate com uma exceção
documentada vale mais que um gate desligado ou cronicamente vermelho.

O que ele **não** alcança é o assunto de §3.A.

---

## 3. Achados

### ALTO

#### A-1 · `color-scheme` nunca é declarado no tema escuro — o browser pinta o que sobra em modo claro

**Medida.** `rg 'color-scheme' web/src` devolve **uma** declaração, e é do tema **claro**:
[`AuthCard.svelte:36`](../web/src/lib/components/AuthCard.svelte) (`style="color-scheme:light…"`).
O `<html>` do app recebe `data-theme="dark"` pelo `hooks.server.ts` e **nada mais**. Para o
browser, o documento continua sendo um documento claro.

**Sonda.** Chromium real, campo com `background:#16181c; color:#eceef0` (os valores de `surface` e
`text` do tema escuro), com e sem `color-scheme:dark` no ancestral. O indicador do seletor de data
(`::-webkit-calendar-picker-indicator`, shadow-DOM da UA) sai **preto** no primeiro caso e branco
no segundo. Preto `#000` sobre `surface` escuro `#16181c` = **1,15:1**.

**O que isso alcança.** Tudo que o CSS do app não consegue repintar porque mora no shadow-DOM da
UA: **9** `type="date"`, **6** `type="time"`, **16** `<select>` (o painel do dropdown é do
sistema), **3** `<textarea>`, mais o realce de autofill do Chrome. Nominalmente:
[`PatientForm.svelte:500`](../web/src/lib/components/patients/PatientForm.svelte),
[`ProfessionalForm.svelte:399`](../web/src/lib/components/professionals/ProfessionalForm.svelte) e
`:607`, [`ExceptionForm.svelte:57`](../web/src/lib/components/scheduling/ExceptionForm.svelte),
[`PeriodEditor.svelte:42`](../web/src/lib/components/scheduling/PeriodEditor.svelte) e `:54`,
[`AddToWaitlistModal.svelte:265`](../web/src/lib/components/fila/AddToWaitlistModal.svelte),
[`PackageCreateModal.svelte:380`](../web/src/lib/components/patients/PackageCreateModal.svelte) e
`:424`, [`PackageGradeModal.svelte:130`](../web/src/lib/components/patients/PackageGradeModal.svelte),
e os `<Field type="date">`/`type="time"` de `NewAppointmentModal` e `RescheduleModal`.

**Por que nenhum gate viu.** O axe não avalia pseudo-elementos da UA nem shadow-DOM fechado — para
ele o campo é `#eceef0` sobre `#16181c` e passa com folga. O `contraste.test.ts` mede pares de
token, e este par não é de token: é do browser. Este é o exemplo mais limpo do doc de um furo que
**só um instrumento novo** encontra.

**O que paga.** Uma linha no `app.css`, no bloco de cada tema:
`color-scheme: light` no claro, `color-scheme: dark` no escuro (e no `@media prefers-color-scheme`).
O `AuthCard` já continua sobrescrevendo o seu localmente, que é o comportamento certo. A trava
natural é um caso novo no `tema-escopo.test.ts`, que já lê o `app.css` da mesma forma.

#### A-2 · `hover:text-white` sobre `hover:bg-accent` reprova em 2,71:1 — e a isenção do gate não cobre

**Medida.** Branco `#ffffff` sobre `--mv-accent-solid` `#7fa59a` = **2,71:1** (calculado; é o mesmo
número que o `app.css:114` registra para o botão primário, porque é a mesma cor).

**Onde.** Dois botões trocam para `bg-accent` + `text-white` no hover:

- [`notificacoes/+page.svelte:198`](../web/src/routes/(app)/notificacoes/+page.svelte) — "marcar como lida"
- [`AppointmentDrawer.svelte:809`](../web/src/lib/components/agenda/AppointmentDrawer.svelte) — ação do drawer

**Por que escapa duas vezes.** Primeiro porque o axe varre o estado renderizado e ninguém está com
o mouse sobre o botão durante a varredura. Segundo porque o filtro de isenção
`semExcecaoDoPrimario` casa `\bbg-primary(-hover)?\b` — estes são `bg-accent`. Ou seja: **se um dia
o axe passasse a medir hover, esta violação chegaria ao relatório sem isenção e quebraria o
build**, e a pessoa que caísse ali não teria o contexto do D-17 para decidir.

**Nota honesta.** O estado normal desses botões (`text-accent-text` sobre `bg-accent-subtle`,
5,30:1) passa. O problema é só o hover. Se a decisão for aceitá-lo, ele precisa ir para o
`50-debitos-tecnicos.md` **junto** com o D-17 e entrar no filtro de isenção — não ficar como está,
que é passar despercebido. Se a decisão for consertar, `text-on-solid` sobre accent dá **6,46:1**.

#### A-3 · O único diálogo artesanal do app não tem nenhuma das quatro garantias que os outros têm

**Onde.** [`PatientAttachments.svelte:407–441`](../web/src/lib/components/patients/PatientAttachments.svelte)
— o modal "Renomear anexo".

| Garantia | `Modal.svelte` | O artesanal |
| --- | --- | --- |
| `role="dialog"` + `aria-modal` | sim (`:50–51`) | **não** |
| Fecha no `Escape` | sim (`:38`) | **não** |
| Tab aprisionado (`aprisionarTab`) | sim (`:53`) | **não** |
| Foco movido ao abrir e devolvido ao fechar | sim (`:31–35`) | **não** |
| Overlay | `bg-[rgba(8,10,12,0.42)]` | `bg-black/40` |
| Raio do painel | `rounded-[12px]` | `rounded-[14px]` |
| Sombra | `shadow-modal` | `shadow-lg` — a sombra **da landing** (`0 30px 80px`) |

**O agravante é interno ao arquivo:** 5 linhas abaixo, o mesmo componente usa `ConfirmDialog`
corretamente (`:444`). Não é desconhecimento do padrão — é um caso que passou por fora dele.

**Por que o gate não pegou.** O `a11y-interno.spec.ts` abre dois diálogos: o Drawer do agendamento
e o Modal de tipo. Este nunca é aberto na varredura. `e2e/a11y-anexos.spec.ts` existe, mas mede se
o input de arquivo está na ordem de tabulação — outro alvo.

**O que paga.** Trocar por `<Modal title="Renomear anexo" onClose={…}>` com o formulário no
`children` e as ações no `footer`. Sai código, não entra. E vale abrir o modal na varredura do axe
como terceiro diálogo.

#### A-4 · `initials()` tem duas implementações que discordam — e a divergente está na tela de relatórios

**Medida.** [`$lib/format.ts:4`](../web/src/lib/format.ts) exporta `initials`, importado em **14
arquivos** e chamado em **24 lugares**. Em
[`relatorios/+page.svelte:52`](../web/src/routes/(app)/relatorios/+page.svelte) há uma **função
local de mesmo nome** que sombreia o import — e que faz `.replace(/^Dr[a]?\.\s*/, '')` antes de
extrair as letras.

**A consequência, computada à mão:** para `"Dra. Ana Silva"`,

| Origem | Resultado |
| --- | --- |
| `$lib/format` (agenda, fila, pacientes, equipe, drawer…) | **`DA`** |
| `relatorios/+page.svelte` | **`AS`** |

O mesmo profissional tem duas iniciais no mesmo produto, dependendo da tela. E como o avatar é
colorido por `cor_indice` e não pelas iniciais, a cor bate e o texto não — o que é pior que
divergirem os dois, porque parece a mesma pessoa até você ler.

**Qual das duas está certa** é decisão de produto (o campo `nome_exibicao` do profissional é
justamente onde se escreve "Dra. Marina", então tirar o prefixo tem lógica). O que não pode é ter
as duas. Qualquer que seja a escolha, ela vai para `format.ts` e a local some — e o `.test.ts` de
`format` ganha o caso `"Dra. Ana Silva"`.

---

### MÉDIO

#### M-1 · Não existe escala tipográfica — 658 tamanhos arbitrários em 22 valores

```
127× text-[13px]     113× text-[12.5px]   105× text-[12px]    70× text-[11px]
 61× text-[11.5px]    44× text-[10.5px]    35× text-[13.5px]  31× text-[10px]
 28× text-[14px]       9× text-[9px]        8× text-[15px]     5× text-[9.5px]
  … + 10 valores com 1–4 usos cada (8px, 8.5px, 16, 17, 18, 19, 20, 23, 24, 15.5px)
```

**261 desses usos são meio-pixel** (`12.5`, `11.5`, `10.5`, `13.5`, `9.5`, `8.5`, `15.5`). A escala
do Tailwind é usada **15 vezes** no app inteiro — 11 `text-sm`, 3 `text-xl`, 1 `text-xs`.

Isso não é acidente: o design veio de um protótipo HTML com valores em px, e a fidelidade ao
protótipo foi (corretamente) priorizada. O custo aparece agora: `12px` e `12.5px` são
indistinguíveis na tela e **carregam papéis diferentes em arquivos diferentes**, sem que nada
diga qual é qual. Quem escreve o próximo componente não tem como acertar — só copiar do vizinho.

Concentração: [`Sidebar.svelte`](../web/src/lib/components/shell/Sidebar.svelte) 36,
[`ProfessionalForm.svelte`](../web/src/lib/components/professionals/ProfessionalForm.svelte) 35,
[`AppointmentDrawer.svelte`](../web/src/lib/components/agenda/AppointmentDrawer.svelte) 35,
[`PackageList.svelte`](../web/src/lib/components/patients/PackageList.svelte) 33.

**O que paga.** Um `@theme` com `--text-meta: 11px`, `--text-corpo: 13px`, `--text-rotulo: 12px`…
nomeados **pelo papel**, não pelo tamanho — a lição que o próprio `app.css` já aplicou nas cores
(`--color-ink`, não `--color-cinza-escuro`). Migração pode ser incremental; o ganho começa no
primeiro componente novo.

#### M-2 · O raio tem 12 valores efetivos e 4 deles têm duas ou três grafias

| Valor final | Grafias no código | Usos |
| --- | --- | --- |
| **8px** | `rounded-lg` (124) + `rounded-md` (63) + `rounded-[8px]` (4) | **191** |
| pill | `rounded-full` | 80 |
| 10px | `rounded-[10px]` | 29 |
| 14px | `rounded-[14px]` | 23 |
| 4px | `rounded` (17) + `rounded-[4px]` (1) | 18 |
| 7px | `rounded-[7px]` | 16 |
| 12px | `rounded-xl` (13) + `rounded-[12px]` (2) | 15 |
| 6px | `rounded-sm` (5) + `rounded-[6px]` (4) | 9 |
| 9px | `rounded-[9px]` | 9 |
| 11px | `rounded-[11px]` | 4 |
| 3px · 5px · 16px | `rounded-[3px]` · `rounded-[5px]` · `rounded-2xl` | 3 · 2 · 1 |

**`rounded-md` e `rounded-lg` renderizam o mesmo 8px.** O `app.css:242–244` mapeia
`--radius-md: var(--mv-radius)` = 8px e `--radius-lg: var(--mv-radius-lg)` = 8px — e o `:26`
documenta *por que* o `lg` virou 8px, mas não notou que isso colidiu com o `md`. Hoje 187 usos
escolhem entre dois nomes idênticos sem critério: `Modal.svelte:61` usa `rounded-[7px]` no botão
de fechar, `ConfirmDialog:41` usa `rounded-md`, `PatientAttachments:424` usa `rounded-lg` — três
botões do mesmo tamanho, três grafias, dois raios.

`rounded` sem sufixo (17 usos) **não passa por token nenhum do projeto**: cai no default do
Tailwind. `rounded-xl`/`rounded-2xl` idem.

**O caso mais visível é o cartão.** O padrão `border border-edge bg-surface` + raio aparece em
**133 lugares com 13 grafias de raio**: 43× `rounded-lg`, 20× `rounded-[14px]`, 19× `rounded-md`,
19× `rounded-[10px]`, 11× `rounded-xl`, 7× `rounded-[7px]`, 4× `rounded-[9px]`, 3× `rounded-full`,
3× `rounded-[11px]`, e mais quatro com 1 uso (`sm`, `2xl`, `[8px]`, `[12px]`). Um cartão de
`/pacientes` e um de `/relatorios` não têm o mesmo canto.

#### M-3 · Dois conjuntos de token de campo concorrentes, e o que perdeu é o dos formulários grandes

[`Field.svelte:7`](../web/src/lib/components/Field.svelte) exporta `CONTROL_CLASS`, com um
comentário que explica exatamente por que ele existe ("cada modal reescrevia a lista à mão e ela
divergiu"). Ele é usado por **7 componentes, 16 controles**.

Mas cinco arquivos declaram um `inputCls` próprio, **quatro deles com a string idêntica**:

| Origem | Classe |
| --- | --- |
| `CONTROL_CLASS` + `CONTROL_PX` | `rounded-md border-edge-strong … px-[11px] text-[13.5px] text-ink placeholder:text-faint` |
| `inputCls` (4 arquivos, verbatim) | `rounded-lg border-edge … px-2.5 text-[13.5px] text-ink` |

Diferenças reais: **borda densa vs. sutil** (cores diferentes), padding 11px vs 10px, e o
`inputCls` **não define `placeholder:text-faint`**. Só 4 elementos no app inteiro declaram cor de
placeholder; os outros **52** herdam o cinza fixo da UA (`#757575`, medido em Chromium).

Quem usa `inputCls`:
[`PatientForm.svelte:362`](../web/src/lib/components/patients/PatientForm.svelte) (30 controles),
[`ProfessionalForm.svelte:285`](../web/src/lib/components/professionals/ProfessionalForm.svelte) (30),
[`perfil/+page.svelte:51`](../web/src/routes/(app)/perfil/+page.svelte),
[`configuracoes/clinica/+page.svelte:56`](../web/src/routes/(app)/configuracoes/clinica/+page.svelte),
[`configuracoes/comunicacao/+page.svelte:66`](../web/src/routes/(app)/configuracoes/comunicacao/+page.svelte) (variante `w-[86px]`).

Ou seja: **o campo do modal e o campo do formulário de cadastro têm bordas de cores diferentes**, e
o do cadastro é o que está fora do padrão — apesar de ser o que a pessoa olha por mais tempo.

#### M-4 · O botão primário tem 23 instâncias e 15 grafias

`class="…bg-primary…"` aparece 23 vezes, em **15 strings distintas**, variando em:

- raio — `rounded-md`, `rounded-lg`, `rounded-[8px]`, `rounded-[9px]`, `rounded-[10px]`
- padding — `px-2.75`/`px-3`/`px-3.5`/`px-4`/`px-5` × `py-1.5`/`py-2`/`py-2.25`/`py-2.5`
- fonte — `text-[12.5px]`, `text-[13px]`, `text-[13.5px]`
- hover — `hover:bg-primary-hover` (a maioria), `hover:opacity-90` (1), **nenhum hover** (4 grafias, 6 instâncias)
- desabilitado — `opacity-60`, `opacity-50`, ausente
- transição — **nenhuma das 15** usa `transition-colors`, enquanto o `Button.svelte` usa

Os quatro sem hover incluem
[`AgendaEmptyState.svelte:23`](../web/src/lib/components/agenda/AgendaEmptyState.svelte) (esse usa
`hover:opacity-90`) e o "Salvar" do modal de renomear (A-3).

#### M-5 · `Button.svelte` existe e é usado **uma vez**

129 `<button>` crus no app. `<Button>` aparece em **um** arquivo:
[`comecar/+page.svelte`](../web/src/routes/comecar/+page.svelte).

A causa é diagnosticável: `Button.svelte:31` começa com `flex w-full` — ele é o botão de **largura
total das telas de auth**, não o botão do app. Como o app quase nunca quer largura total, o
componente ficou inutilizável e cada tela rolou o seu. `SubmitButton` (34 usos) resolveu o outro
eixo — estado "em voo", `aria-busy`, giro — e explicitamente **não impõe visual** ("a classe do
chamador passa inteira", `:5`). Então o app tem um componente que cuida do comportamento e nenhum
que cuide da aparência.

**Extração candidata nº 1:** um `Button` com `variant` (primary/secondary/ghost/danger),
`size` (sm/md) e `icon-only`, absorvendo o `SubmitButton` como estado. As 15 grafias de M-4 e as
do botão secundário (`border border-edge bg-surface …` aparece em **104 strings distintas**, das
quais boa parte é cartão e não botão — não separei as duas famílias) colapsariam em 4 variantes.

#### M-6 · z-index sem escala — 9 valores crus, e dois deles trocados

| z | Onde |
| --- | --- |
| 5, 6, 7, 8, 9 | `DayGrid.svelte:368,369,391,485,499` · `ProfessionalChips.svelte:25` |
| 40 | `Drawer:54` · `UserMenu:38` (backdrop) · `PackageList:404` (backdrop) · `+layout:178` (gaveta) |
| 50 | `Modal:42` · `UserMenu:56` · `PackageList:408` · `PatientAttachments:408` |
| 60 | `Toast:40` |
| 70 | `+layout:124` (skip link) |

A camada 40/50/60/70 tem uma ordem coerente e não achei conflito real. O problema é que ela é
**convenção oral**: nada impede o próximo popover de nascer com `z-50` e ficar por baixo do
`Toast`, ou por cima de um `Drawer`. Quatro tokens (`--z-overlay`, `--z-modal`, `--z-popover`,
`--z-toast`, `--z-skip`) tornariam a regra legível no lugar onde ela é decidida.

#### M-7 · Quatro tokens definidos e nunca usados — um deles é a única sombra que muda por tema

| Token | Usos no `src/` |
| --- | --- |
| `--color-accent-hover` (`#72958b`) | **0** |
| `--color-success-solid` (`#2da160`) | **0** |
| `--shadow-accent` | **0** |
| `--shadow-card` | **0** |

O `--shadow-card` merece nota. A cadeia é `--mv-shadow-card` → `--mv-card-shadow` (que vale a
sombra no claro e **`none` no escuro**, `app.css:141` e `:186`) → `--shadow-card`. É a única
sombra do sistema que responde ao tema, foi desenhada de propósito, e **nenhum cartão do app a
aplica**. Os 108 cartões de M-2 não têm sombra em tema nenhum. A intenção de design evaporou em
silêncio — o token continua lá dizendo que ela existe.

`--color-success-solid` é o par ausente de uma família: `warning-solid` (5 usos),
`danger-solid` (3), `info-solid` (1) são usados; o verde não. Não é bug, mas é sinal de que a
família nasceu por simetria e não por necessidade medida.

**Quase-duplicados.** `--mv-accent-hover` e `--mv-primary-hover` valem ambos `#72958b`; o
`app.css:71–75` documenta os **três** tokens que valem `#7fa59a` e explica a separação por papel —
mas não menciona este quarto e quinto. Vale estender o comentário.

#### M-8 · O avatar do usuário logado tem hex cru, enquanto `$lib/avatar.ts` existe

[`UserMenu.svelte:49`](../web/src/lib/components/shell/UserMenu.svelte) e
[`perfil/+page.svelte:60`](../web/src/routes/(app)/perfil/+page.svelte) escrevem
`bg-[#0072B2] … text-white`. Esse hex é `AVATAR_PALETTE[1]` de
[`avatar.ts:22`](../web/src/lib/avatar.ts) — o módulo que existe exatamente para isso e que
`avatarStyle()` serve em **14 outros lugares**, com a lógica de contraste do texto embutida
(`textoSobre`, com a exceção `SEMPRE_BRANCO`).

Se a paleta de avatar mudar, o avatar do usuário logado fica para trás. E ele é o único avatar do
app cuja cor de texto não passou pelo `textoSobre`.

#### M-9 · Sobreviveu um hex que o comentário do próprio arquivo diz ter saído

[`PackageList.svelte:137`](../web/src/lib/components/patients/PackageList.svelte) traz o comentário:

> Era o hex cru `#9a6a05` — um conserto de contraste feito à mão, fora da paleta e invisível para
> o tripwire. Agora é o próprio token de texto do âmbar…

E o conserto de fato aconteceu — no mapa `CHIP`. Mas **194 linhas abaixo**, na linha 332, o mesmo
hex continua vivo:

```svelte
? 'font-semibold text-[#9a6a05]'
```

É o rótulo "N restantes" do contador de pacote. Fora da paleta, sem par medido, invisível para o
`contraste.test.ts` (que só lê tokens) e **igual nos dois temas** — `#9a6a05` sobre
`surface` escuro `#16181c` não foi medido por ninguém. O token correto (`text-warning`) já está
no arquivo, uma linha acima.

---

### BAIXO

- **B-1 · `quando()` implementada 5 vezes.** `PatientUpcoming.svelte:26` e `PatientHistory.svelte:24`
  são **byte-idênticas**; `PackageList.svelte:127` e `PackageSessionsModal.svelte:78` são variantes
  do mesmo formato ("dow dd/mm · hh:mm"); `MessageTimeline.svelte:54` usa `Intl`. Todas fazem
  "instante ISO → data e hora no fuso da clínica". Mora em `.svelte`, portanto **fora do alcance de
  teste de unidade de lógica** — o único jeito de cobrir é montar o componente.

- **B-2 · O array de dias da semana, 3 vezes, com 3 nomes.** `DOW` (`PackageSessionsModal:77`),
  `DOW_UTC` (`PackageCreateModal:277`), `DOW_CURTO` (`PackageList:126`) — todos
  `['Dom','Seg',…]`. E [`packages.ts:92`](../web/src/lib/packages.ts) já exporta `DOW_LABELS` com
  exatamente esse conteúdo; `PackageCreateModal` **importa `DOW_LABELS` na linha 33 e declara
  `DOW_UTC` na 277**, no mesmo arquivo.

- **B-3 · Estado vazio: 16 lugares, 1 componente.** `AgendaEmptyState` existe e o seu comentário
  explica bem por que ("cada visão degradava para uma frase FALSA diferente"). O mesmo argumento
  vale para os outros 15 — `/pacientes:200-206` sozinho tem 4 frases de vazio distintas.

- **B-4 · Badge/pílula: 23 grafias inline contra 3 componentes.** `RoleBadge`, `StatusBadge` e
  `PriorityBadge` existem, cada um em uma subpasta, e nenhum compartilha base — as três geometrias
  são `rounded-full px-2.5 py-[3px] text-[11.5px]`, `text-[11px]` sem pílula, e
  `rounded-full px-[9px] py-0.5 text-[10.5px]`. Fora deles há 23 strings inline com o mesmo papel.
  **Extração candidata nº 2:** um `Badge` com `tone` e `size`.

- **B-5 · `/perfil` tem dois `<h1>`.** O `Topbar.svelte:43` emite um `<h1>` para toda rota do app
  (bom — as 19 rotas têm cabeçalho de nível 1 sem repetir código), e
  [`perfil/+page.svelte:65`](../web/src/routes/(app)/perfil/+page.svelte) emite outro. É a única
  rota que faz isso. Não é violação WCAG (nem a regra `page-has-heading-one` do axe, que é
  best-practice e está fora das tags usadas), mas é a única quebra do padrão em 19 telas.
  `MessageTimeline` e `AuditEntry` usam `<h3>` sem `<h2>` no mesmo componente — aqui o nível certo
  depende do contexto de montagem e não dá para afirmar erro sem medir a árvore renderizada.

- **B-6 · O overlay tem dois valores e três grafias.** `bg-[rgba(8,10,12,0.42)]`
  (`Modal:42`, `Drawer:54`) e `bg-black/40` (`+layout:182`, `PatientAttachments:408`). Um
  `--mv-overlay` resolveria — e faria o A-3 se denunciar sozinho.

- **B-7 · 201 utilitários `hover:` e 7 elementos com transição.** Só 24 usos de `transition-*` no
  app inteiro. Pode ser escolha (interface administrativa, resposta imediata), mas então o
  `Button.svelte` e o `SwitchToggle` — que animam — é que estão fora do padrão. Vale decidir de
  qual lado.

- **B-8 · 17 tamanhos de ícone em 254 usos** (`size={15}` 65×, `size={14}` 52×, `size={13}` 30×,
  `size={16}` 29×, `size={12}` 23×, `size={11}` 17×, mais 11 valores com 1–11 usos). Mesmo
  diagnóstico de M-1, escala menor. 93 ícones lucide distintos importados.

- **B-9 · Dois arquivos pedem quebra.**
  [`Sidebar.svelte`](../web/src/lib/components/shell/Sidebar.svelte) tem 596 linhas e é **sete
  barras laterais contextuais** num arquivo (profissionais, pacientes, fila, agenda, auditoria,
  configurações, relatórios), com 22 imports de ícone.
  [`agenda/+page.svelte`](../web/src/routes/(app)/agenda/+page.svelte) tem **562 linhas de
  `<script>` para 150 de markup** (318 linhas não-comentário) — orquestração de drag-to-reschedule,
  realtime, seleção, querystring. O maior de todos,
  [`AppointmentDrawer.svelte`](../web/src/lib/components/agenda/AppointmentDrawer.svelte) (1.034
  linhas), é grande mas equilibrado (369 script / 665 markup) e tem teste ao lado — é o menos
  urgente dos três.

- **B-10 · 7 componentes sem `.svelte.test.ts`:** `Seo`, `agenda/AgendaEmptyState`,
  `agenda/ConflictErrorBox`, `agenda/EncaixeCheckbox`, `agenda/OccupancyBar`, `cinetra/FlowArt`,
  `members/StatusBadge`. Contra 58 que têm — a cobertura de componente é boa e esta é a lista
  curta do que falta.

- **B-11 · O `Drawer` não anima na entrada.** `Modal:49` usa `animate-scale`; `Drawer:63` não usa
  nada. Os dois tokens de animação (`--animate-fade`, `--animate-scale`) têm 1 uso cada.

- **B-12 · O cromo colapsa em `lg:` e as tabelas em `md:`.** `+layout.svelte:131/178` usa
  `hidden lg:flex` / `lg:hidden`; as quatro listas de dados (`/pacientes`, `/profissionais`,
  `/fila`, `/configuracoes/equipe`) trocam para cartão em `md:`. Entre 768px e 1023px a tela fica
  sem sidebar **e** com a tabela em modo desktop. Distribuição geral: 82 `md:`, 16 `sm:`, 4 `lg:` —
  ou seja, o `lg:` do shell é a exceção, não a regra. Não medi se o resultado quebra a 800px; é
  uma sonda de 5 minutos no browser.

---

## 4. Inventários

### 4.1 Uso dos tokens de cor (utilitários `bg-`/`text-`/`border-`… no `src/`)

```
surface 342   edge 287   faint 243   muted 227   accent 208   surface-2 169
ink 127   danger 94   accent-text 91   primary 60   accent-subtle 47   warning 46
on-primary 35   edge-strong 18   canvas 15   primary-hover 15   accent-border 13
on-solid 13   rail 9   success 7   rail-item 6   warning-solid 5   info 3
blue 2   danger-solid 2   sage 2   info-solid 1   wordmark 1
accent-hover 0   success-solid 0
```

### 4.2 Onde os literais de cor ainda estão (app interno)

| Arquivo:linha | Literal | Veredito |
| --- | --- | --- |
| `UserMenu.svelte:49` | `bg-[#0072B2]` | **M-8** |
| `perfil/+page.svelte:60` | `bg-[#0072B2]` | **M-8** |
| `PackageList.svelte:332` | `text-[#9a6a05]` | **M-9** |
| `Modal.svelte:42` · `Drawer.svelte:54` | `bg-[rgba(8,10,12,0.42)]` | B-6 (falta token) |
| `+layout.svelte:182` · `PatientAttachments.svelte:408` | `bg-black/40` | B-6 |
| `Rail.svelte:65` · `SwitchToggle.svelte:29` | `bg-white` | ok (marca / knob) |
| `OfferSlotModal:237` · `fila:336` | `bg-white/25` | ok (chip sobre cor) |
| `ConfirmDialog.svelte:54` | `text-white` | ok (medido no `contraste.test.ts`) |
| `Rail.svelte:78/79/97/98` · `ThemeToggle:16` | `text-white/60` | ok (rail é escuro nos dois temas) |

### 4.3 Cobertura dos instrumentos existentes — e o buraco de cada um

| Instrumento | Alcança | **Não** alcança |
| --- | --- | --- |
| `contraste.test.ts` (CI) | todo par de token, dois temas | cor que não é token (M-9); pseudo-elemento da UA (A-1) |
| `a11y-interno.spec.ts` (CI, gate) | 17 rotas + 2 diálogos + 2 estados mobile, axe wcag2aa | estado `:hover` (A-2); diálogo não aberto na varredura (A-3); shadow-DOM da UA (A-1) |
| `a11y-teclado.spec.ts` (relata) | Tabs, escape, reflow 320/640, axe no escuro | idem |
| `contraste-tokens.mjs` (manual) | tabela de pares para colar em doc | não roda no CI (deliberado) |
| `npm run coverage` (CI, 80%) | `src/lib/**`, hooks, route handlers `.ts` | **lógica dentro de `.svelte`** — é onde vivem B-1 e A-4 |
| `svelte-check` (CI) | tipos, a11y do compilador Svelte | consistência visual (nada aqui) |

A última linha da tabela é a leitura mais útil do doc: **nenhum instrumento do projeto olha para
consistência de dimensão**. Os 1.014 utilitários arbitrários passam por seis gates sem tocar em
nenhum, porque cada um deles é sintaticamente válido e individualmente legítimo.

---

## 5. Ordem sugerida — do que rende mais por linha mexida

Sem prazo e sem promessa: é uma ordenação por razão custo/efeito, para quem for decidir.

1. **A-1** (`color-scheme`) — três linhas de CSS, conserta 34 controles nativos no tema escuro.
2. **M-9** (`text-[#9a6a05]`) — uma palavra, e fecha um comentário que hoje mente.
3. **A-4** (`initials`) — apagar uma função, ajustar `format.ts`, somar um caso de teste.
4. **A-3** (modal artesanal) — troca por `<Modal>`; **sai** código. Somar o diálogo à varredura do axe.
5. **A-2** (`hover:text-white`) — decisão humana: consertar (`text-on-solid`, 6,46) ou registrar em
   `50-debitos-tecnicos.md` junto ao D-17 e estender o filtro de isenção. **Não deixar como está.**
6. **M-8** (avatar `#0072B2`) — usar `avatarStyle`, duas linhas.
7. **M-7** (tokens órfãos) — decidir por cada um: usar `--shadow-card` nos cartões (era a intenção)
   ou remover; remover `accent-hover`/`success-solid`/`shadow-accent` ou justificá-los no comentário.
8. **M-3** (dois conjuntos de campo) — apagar os 5 `inputCls` e usar `CONTROL_CLASS`. Mudança
   **visível**: a borda dos formulários grandes fica mais densa. Vale olhar no browser antes.
9. **M-2 + M-1** (escala de raio e de fonte) — os maiores, e os únicos que pedem plano.
   Sugestão de sequência: (a) tokenizar por papel; (b) colapsar `rounded-md`/`rounded-lg` num nome
   só; (c) migrar por área, começando por `patients/` e `professionals/`, que concentram o maior
   número de arbitrários; (d) só então considerar um lint que barre `text-[…px]` novo.
10. **M-5 + M-4 + B-4** (`Button` e `Badge` de verdade) — depende de (9): extrair componente antes
    de ter escala é congelar as 15 grafias em código.

Fora da ordem, porque são baratos e independentes: **B-2** (usar `DOW_LABELS`), **B-10** (7 testes
de componente), **B-5** (o `<h1>` duplicado de `/perfil`).

---

## 6. O que este doc não mediu

Para não passar por completo o que não é:

- **Nada foi aberto no browser além da sonda do `color-scheme`.** B-12 (a faixa 768–1023px),
  o efeito visual de M-3 e a legibilidade real dos 22 tamanhos de fonte pedem olho na tela.
- **Não medi bundle nem performance de render.** Os 93 ícones lucide e os 1.014 utilitários têm
  custo de CSS gerado que não estimei.
- **`interface/` não foi comparado linha a linha.** Ele é a origem dos valores em px e é
  regenerado por ferramenta; a pergunta "o app ainda bate com o protótipo" é outra auditoria.
- **A hierarquia de headings dentro dos componentes** (B-5, segundo parágrafo) precisa da árvore
  renderizada para virar veredito; aqui só apontei os dois arquivos suspeitos.
