# 94 — Reúso de componentes, idioms de Svelte 5 e manutenibilidade do `web/`

**Data:** 2026-07-30 · **Escopo:** `web/src/` — 65 componentes em `lib/components/`, 29 rotas
`.svelte`, 41 módulos em `lib/*.ts`, 23 em `lib/server/*.ts`, os 32 `$effect` do repositório ·
**Natureza:** só análise. **Nada foi mudado.**

**Relação com o [doc 93](93-auditoria-design-system-web.md).** Aquele mediu a **superfície** — cor,
raio, tamanho, contraste, tokens. Este mede a **estrutura** — quem chama quem, se o código diz o
que quer dizer em Svelte 5, e onde a base vai doer para mexer daqui a seis meses. Há três pontos de
contato, e eles são referenciados, não repetidos: o `Button` de um uso só (93 §M-5), as 15 grafias
de botão primário (93 §M-4) e os dois conjuntos de token de campo (93 §M-3). Aqui eles reaparecem
só como consequência estrutural.

**Método.** O mesmo: contagem, não impressão. As contagens de call-site usam correspondência
exata do nome da tag (`<Nome` seguido de espaço, `/`, `>` ou fim de linha) — a primeira tentativa,
por substring, contava `SubmitButton` como uso de `Button` e é por isso que este doc não tem os
números da conversa e sim os do script.

**Manchete.** O idiom de Svelte 5 está **acima da média por uma margem larga** — e a parte mais
difícil (efeitos) foi a que saiu melhor: não há um único caso do antipadrão clássico. O que a base
tem é outra coisa: **estruturas inteiras copiadas** entre telas com o mesmo papel — dois formulários
de cadastro gêmeos (1.577 linhas), quatro rodapés de paginação idênticos, três blocos de token de
tempo real verbatim, sete reações a `form` com sete formatos. E um vão de contrato entre o BFF e o
browser: **16 `fetch` do cliente, nenhum tipado contra o `+server.ts` que responde.**

---

## 1. Retrato em números

| Medida | Valor | § |
| --- | --- | --- |
| Componentes em `lib/components/` | 65 | |
| ├ com **2 ou mais** call-sites | **26** (40%) | 2.1 |
| ├ single-use com ≥150 linhas (extração legítima por tamanho) | **16** | 2.1 |
| └ single-use com <60 linhas (a lista a examinar) | **10** | 2.2 |
| `$effect` no repositório | **32** | 3.1 |
| ├ efeito colateral real, **com cleanup** | 17 | 3.1 |
| ├ reação a resultado de `form` action | 7 | 3.2 |
| ├ reset/latch de estado (escape hatch legítimo) | 7 | 3.1 |
| └ **derivação disfarçada de `$derived`** | **0** | 3.1 |
| `$effect.pre` · `$effect.root` · `$effect.tracking` | 0 · 0 · 0 | 3.1 |
| `onMount` | **0** | 3.1 |
| `untrack(() => …)` — captura de valor inicial | **61**, em 15 arquivos (47 semeando `$state`) | 3.3 |
| `setContext` / `getContext` | **0** | 3.5 |
| Módulos `.svelte.ts` com estado em runes | **4** (`toast`, `forms`, `media`, `anuncio`) | 3.4 |
| `{#snippet}` declarados · `{@render}` | 50 · 133 | 3.6 |
| Props do tipo `Snippet` | 12 | 3.6 |
| `any` no código de produção | **0** | 4.4 |
| `@ts-ignore` / `@ts-expect-error` / `eslint-disable` | **0** | 4.4 |
| Declarações de tipo dentro de `.svelte` | **6** | 4.4 |
| `fetch()` chamados do browser | 16 | 4.5 |
| └ tipados contra o `+server.ts` que respondem | **0** | 4.5 |
| Componentes com `.svelte.test.ts` | 58 de 65 | 4.7 |

---

## 2. Reúso de componentes

### 2.1 O inventário

**26 dos 65 componentes têm dois ou mais call-sites.** Os que puxam o reúso:

| Componente | Call-sites | Arquivos que importam | Linhas |
| --- | --- | --- | --- |
| `SubmitButton` | **34** | 22 | 57 |
| `Field` | **29** | 10 | 90 |
| `Modal` | **12** | 12 | 75 |
| `ConfirmDialog` | **9** | 7 | 60 |
| `scheduling/SwitchToggle` | 8 | 5 | 33 |
| `scheduling/PeriodEditor` | 5 | 5 | 87 |
| `agenda/ConflictErrorBox` | 5 | 5 | 41 |
| `agenda/AgendaEmptyState` · `Logo` · `fila/PriorityBadge` · `Seo` | 4 | 3–4 | 16–68 |
| `scheduling/ConflictsModal` · `agenda/OccupancyBar` · `agenda/EncaixeCheckbox` · `AuthCard` | 3 | 3 | 20–99 |

Os quatro do topo são **os primitivos que funcionaram**, e vale entender por quê: cada um resolve
uma coisa que **doía em todo lugar** (o estado "em voo", o rótulo associado ao input, a casca do
diálogo, a confirmação destrutiva) e **não impõe visual**. `SubmitButton:5` diz isso explicitamente
— "a classe do chamador passa inteira". É o oposto do `Button` (93 §M-5), que impõe `w-full` e por
isso serve a uma tela só.

Os **39 restantes têm um call-site**. Isso **não** é dead code — é o resultado esperado de uma
arquitetura por área. A leitura útil é por tamanho:

- **16 são grandes (≥150 linhas)**: `AppointmentDrawer` (1.034), `PatientForm` (823),
  `ProfessionalForm` (754), `Sidebar` (596), `PackageList` (583), `PackageCreateModal` (578),
  `DayGrid` (517), `PatientAttachments` (452)… Extração **por tamanho**, que é motivo válido —
  a página ficaria ilegível com eles inline. Nenhum é dead code.
- **13 são médios (60–150 linhas)** e igualmente justificados (`Rail`, `MemberModal`,
  `AccessMatrixTable`, `WeekView`…).
- **10 são pequenos (<60 linhas)** — a lista curta que vale examinar, em §2.2.

**Nenhum componente do repositório tem zero call-sites.** Rodei a contagem duas vezes com regex
diferentes; não há órfão.

### 2.2 Os dez single-use pequenos — veredito individual

| Componente | Linhas | Veredito |
| --- | --- | --- |
| `members/StatusBadge` | 16 | **candidato a fundir** — ver §2.4 (família de badges) |
| `members/RoleBadge` | 35 | **candidato a fundir** — idem |
| `GoogleIcon` | 23 | ok — SVG isolado, evita 20 linhas de path no `AuthForm` |
| `shell/Topbar` | 46 | ok — parte do cromo, montado 1× por definição |
| `ThemeToggle` | 48 | ok — encapsula `localStorage` + `matchMedia` |
| `agenda/ProfessionalChips` | 48 | ok — o comentário `:6` registra a regra do primeiro nome |
| `audit/FieldDiff` | 50 | ok — recursivo por natureza (diff aninhado) |
| `agenda/DayViewers` | 53 | ok — presença em tempo real, lógica própria |
| `Toast` | 54 | ok — singleton do shell, pareado com `toast.svelte.ts` |
| `Button` | 51 | **problema** — ver 93 §M-5 |

Ou seja: dos 39 single-use, **três** merecem ação, e dois deles pela mesma razão (§2.4).

### 2.3 Duplicação estrutural — as provas

Esta é a seção central do doc. Cinco padrões repetidos, todos verificáveis lado a lado.

#### D-1 · Os dois formulários de cadastro são gêmeos — 1.577 linhas

[`PatientForm.svelte`](../web/src/lib/components/patients/PatientForm.svelte) (823) e
[`ProfessionalForm.svelte`](../web/src/lib/components/professionals/ProfessionalForm.svelte) (754)
compartilham o **esqueleto inteiro**. A prova mais direta é que a **linha 3 dos dois é o mesmo
comentário**:

> `// cabeçalho (avatar + barra de progresso X/Y), coluna "SEÇÕES" com contador por seção,`

E a estrutura confirma, item por item:

| Peça | `PatientForm` | `ProfessionalForm` |
| --- | --- | --- |
| `runCepLookup` | `:221` | `:147` |
| `onCepInput` | `:239` | `:166` |
| `const SECTIONS = [...]` | `:333` | `:257` |
| `const totalKeys = SECTIONS.reduce(...)` | `:343` | `:265` |
| laço de seção corrente (`let cur = SECTIONS[0].id`) | `:351` | `:274` |
| `function goSec(id)` | `:358` | `:281` |
| `const inputCls` | `:362` | `:285` |
| `{#each SECTIONS as s (s.id)}` (coluna lateral) | `:428` | `:364` |
| snippet `cardHead(...)` | `:451` | `:387` |
| `submitting = $bindable(false)` | `:39` | `:51` |

`runCepLookup` é **byte-idêntico a menos do nome de uma variável local** (`d` vs `digits`) — 18
linhas cada:

```ts
// PatientForm.svelte:221                    // ProfessionalForm.svelte:147
const d = cep.replace(/\D/g, '');            const digits = cep.replace(/\D/g, '');
if (d.length !== 8) { cepStatus = null; …    if (digits.length !== 8) { cepStatus = null; …
cepReq = d;                                  cepReq = digits;
cepStatus = 'loading';                       cepStatus = 'loading';
const { status, address } = await lookupCep(d);   … await lookupCep(digits);
if (cepReq !== d) return;                    if (cepReq !== digits) return;
…                                            …
```

`goSec` é literalmente a mesma linha:
`document.getElementById(\`sec-${id}\`)?.scrollIntoView({ behavior: 'smooth', block: 'start' })`.

**O que isso custou já.** Os dois `inputCls` também são idênticos — e são justamente os que
divergem do `CONTROL_CLASS` do `Field` (93 §M-3). A divergência entrou **duas vezes** porque o
arquivo foi copiado antes de o `Field` existir, e depois ninguém tinha um lugar só para consertar.

**Extração proposta (a maior do doc).** Três peças, todas em `lib/`:

1. `lib/cep.svelte.ts` → `criarCep(f)`: encapsula `cepStatus`/`cepReq`/`runCepLookup`/`onCepInput`.
   **Unifica 2 call-sites, ~40 linhas**, e ganha teste de unidade (hoje só é exercitado por dois
   testes de componente).
2. `lib/form-secoes.ts` → `progresso(SECTIONS, counts)` e `secaoCorrente(SECTIONS, scrollTop)`:
   lógica pura, hoje presa em `.svelte` e portanto fora do gate de cobertura (§4.1).
3. `components/FichaShell.svelte` — o cromo: avatar + barra X/Y + coluna de seções + `cardHead`.
   API: `{ titulo, iniciais, corIndice, secoes: Secao[], counts: Record<string, number>, children:
   Snippet, rodape?: Snippet }`. **Unifica 2 call-sites e ~250 linhas de markup**, e é o passo
   que torna um terceiro cadastro (convênio? unidade?) barato em vez de uma terceira cópia.

#### D-2 · O rodapé de paginação, quatro vezes

Quatro rotas repetem o mesmo bloco: [`pacientes:213`](../web/src/routes/(app)/pacientes/+page.svelte),
[`fila:536`](../web/src/routes/(app)/fila/+page.svelte),
[`notificacoes:208`](../web/src/routes/(app)/notificacoes/+page.svelte),
[`auditoria:136`](../web/src/routes/(app)/auditoria/+page.svelte).

Mesma guarda (`{#if data.pageInfo.more || data.current > 1}`), mesmo `goPage(n)`, mesmos dois
botões com `ChevronLeft`/`ChevronRight` e os rótulos "Anterior"/"Próxima". E — a prova mais limpa —
**a classe do botão é a mesma string de 200 caracteres, copiada verbatim nos quatro**:

```
auditoria/+page.svelte:53      notificacoes/+page.svelte:55
fila/+page.svelte:104          pacientes/+page.svelte:90
  const navBtn =
    'inline-flex items-center gap-1 rounded-lg border border-edge bg-surface px-2.5 py-1.5
     text-[12.5px] font-semibold text-ink hover:bg-surface-2 disabled:opacity-40
     disabled:hover:bg-surface';
```

As diferenças entre as quatro cópias são só ruído acumulado: `mt-3` vs `mt-4`, `px-1` a mais na
fila, e `notificacoes` **não mostra o rótulo "X–Y de Z"** enquanto as outras três mostram (ali é
deliberado — o comentário `:38` diz que a API não conta o total).

**Extração:** `components/Paginacao.svelte` com
`{ current, pageInfo, onPage, label?: string | null }`. **Unifica 4 call-sites** e apaga as quatro
declarações de `navBtn`.

#### D-3 · O token de tempo real, três vezes verbatim

[`+layout.svelte:54–68`](../web/src/routes/(app)/+layout.svelte),
[`agenda/+page.svelte:102–119`](../web/src/routes/(app)/agenda/+page.svelte),
[`fila/+page.svelte:152–166`](../web/src/routes/(app)/fila/+page.svelte).

O corpo é idêntico nos três — mesmo `fetch('/api/realtime/token')`, mesma cadeia
`.then(r => r.ok ? r.json() : null)`, mesma guarda `vivo`, mesmo
`.catch(e => reportar('realtime:token', e))`, mesmo cleanup. **Só o comentário muda**, e ele é o
mesmo argumento reescrito ("mata o tempo real de todo o app" / "da agenda" / "da tela").

**Extração:** `lib/realtime-token.svelte.ts` → `usarTokenRealtime(): { cfg: RealtimeConfig | null }`,
com o `$effect` e o cleanup dentro. **Unifica 3 call-sites, ~45 linhas.** É o mesmo movimento que
`media.svelte.ts` já fez para `matchMedia` — o padrão existe no repo, só não foi aplicado aqui.

#### D-4 · A busca de paciente, duas vezes

```ts
// agenda/+page.svelte:516                    // fila/+page.svelte:108
async function search(q: string): Promise<SearchResult> {
  const res = await fetch(`/agenda/pacientes?q=…`);   //   `/fila/pacientes?q=…`
  if (!res.ok) return { patients: [], total: 0 };
  return (await res.json()) as SearchResult;
}
```

Idêntico exceto a URL. Vira `lib/patient-search-client.ts` → `buscarPacientes(base, q)`, **2
call-sites**. E os dois endpoints (`/agenda/pacientes` e `/fila/pacientes`) provavelmente também
querem virar um — não verifiquei se divergem no servidor.

#### D-5 · O mapa `id → nome` de profissional, duas vezes

[`pacientes/+page.svelte:77`](../web/src/routes/(app)/pacientes/+page.svelte) e
[`pacientes/[id]/+page.svelte:80`](../web/src/routes/(app)/pacientes/[id]/+page.svelte) fazem
`Object.fromEntries(data.professionals.map((p) => [p.id, p.nome])) as Record<string, string>` —
inclusive o mesmo cast. E `lib/agenda.ts` já exporta `patientNameMap` para o caso simétrico dos
pacientes; falta o de profissionais.

### 2.4 Padrões estruturais sem componente

Estes não são "código duplicado" no sentido do §2.3 — são **papéis visuais repetidos** que nunca
viraram componente. Os números de grafia estão no doc 93; aqui vai a leitura de arquitetura.

| Papel | Componentes existentes | Reimplementações inline | Extração proposta |
| --- | --- | --- | --- |
| **Badge/pílula** | `RoleBadge`, `StatusBadge`, `PriorityBadge` — 3 componentes, **3 geometrias diferentes, base zero compartilhada** | 23 strings inline (93 §B-4) | `Badge` com `{ tone, size, icon?, children }` — absorve os 3 e ~15 dos 23 inline |
| **Estado vazio** | `AgendaEmptyState` (4 usos) | 15 lugares (93 §B-3), sendo 4 só em `pacientes:200-206` | `EstadoVazio` com `{ icone, titulo, descricao?, acao?: Snippet }` — **~16 call-sites** |
| **Rodapé de paginação** | nenhum | 4 (D-2) | `Paginacao` — 4 call-sites |
| **Botão** | `Button` (1 uso, inutilizável) | 129 `<button>` crus | ver 93 §M-5 |
| **Tabela responsiva** (grade `md:` + cartão abaixo) | nenhum | 4: `pacientes:88`, `profissionais:43`, `fila:270`, `equipe:139` — cada um com o seu `const COLS` e o par `hidden md:grid` / `md:hidden` | provavelmente **não** vale componente: as colunas divergem demais. Vale extrair só o `COLS`/cabeçalho num snippet local |
| **Skeleton / carregando** | **nenhum** | ver §4.6 — o app não tem skeleton em lugar nenhum | — |

### 2.5 O inverso: componentes que pedem QUEBRA

Contei props de topo por componente (parser de vírgulas em profundidade 0):

| Componente | Props | Linhas | Diagnóstico |
| --- | --- | --- | --- |
| `agenda/DayGrid` | **15** | 517 | grade + arraste + disponibilidade + presença — ver §4.2 |
| `SubmitButton` | 14 | 57 | **falso positivo** — 11 são repasse de atributos HTML (`form`, `name`, `value`, `title`…). Props de comportamento: 3 |
| `Field` | 14 | 90 | idem — 10 são atributos de `<input>` |
| `agenda/AppointmentDrawer` | 13 | 1.034 | §4.2 |
| `agenda/AppointmentBlock` | 12 | 306 | 3 flags booleanas (`compacto`, `arrastavel`, `selecionado`) |
| `agenda/RescheduleModal` | 11 | 163 | ok para um modal de remarcação |

**Flags booleanas por componente** — o sinal clássico de duas responsabilidades: o máximo do repo é
**3** (`AppointmentBlock`, `SubmitButton`, `Button`), e em nenhum dos três as flags se combinam em
modos mutuamente exclusivos. **Não há um único componente com o antipadrão `if (modoA) … else
modoB` guiado por prop.** Isso é bom e vale dizer.

O caso real de quebra é outro e não aparece na contagem de props:
[`shell/Sidebar.svelte`](../web/src/lib/components/shell/Sidebar.svelte) — 596 linhas, 1 prop, e
**sete barras laterais contextuais** num arquivo (profissionais, pacientes, fila, agenda,
notificações, relatórios, auditoria, configurações). O acoplamento aparece em §4.4: ele lê
**20 chaves diferentes de `page.data`**, cada uma com um cast, porque é o único ponto do app que
conhece o `data` de sete rotas ao mesmo tempo.

---

## 3. Idioms de Svelte 5

### 3.1 Os 32 `$effect`, classificados — e o resultado é bom

Li os 32 um a um. A classificação:

| Categoria | Nº | Veredito |
| --- | --- | --- |
| **Efeito colateral real, com função de limpeza** | **17** | legítimo |
| Reação a resultado de `form` action (toast, fechar modal) | 7 | legítimo, mas §3.2 |
| Reset/latch de estado ao mudar uma chave | 7 | escape hatch reconhecido, §3.1.1 |
| Leitura de ambiente do browser (`localStorage`) | 1 | legítimo (`AgendaLegend:49`, com o motivo escrito) |
| **Derivação disfarçada — `$effect` onde `$derived` bastava** | **0** | — |

**Zero ocorrências do antipadrão clássico.** Não há um `$effect(() => { b = a * 2 })` no
repositório. Para uma base com 32 efeitos, isso é notável, e é o achado mais forte desta seção.

Os 17 com cleanup são todos do mesmo molde correto — `let vivo = true` … `return () => { vivo =
false }` para `fetch`, ou `return connectX(...)` devolvendo o disconnect direto:

- foco de diálogo com restauração: `Modal:31`, `Drawer:45`, `+layout:41`
- token de tempo real: `+layout:54`, `agenda:102`, `fila:152` (e são o D-3)
- socket: `+layout:75`, `agenda:155`, `fila:186`, `fila:209`
- `fetch` de dado sob demanda: `agenda:377` (timeline), `agenda:423` (candidatos), `fila:120`
  (vagas), `PackageSessionsModal:41`, `OfferSlotModal:77`, `PackageCreateModal:163`
- cleanup puro: `+layout:87` — `$effect(() => () => anunciante.limpar())`

**Nenhum efeito que abre recurso ficou sem cleanup.** Verifiquei os 17.

#### 3.1.1 Os sete resets — por que não são bug

`agenda:92` (`live = null` quando o load traz dados novos), `agenda:224` (`viewers = []` ao trocar
de tópico), `agenda:341` (`remarcando = false` quando o bloco sai da janela), `agenda:270` (abre o
modal quando chega `?paciente=`), `pacientes/[id]:53` (`ajustandoGrade = null` no sucesso),
`pacientes:45` (`term = q`, exceto durante digitação), `OfferSlotModal:71` (default do `<select>`).

Todos são **acumuladores ou latches**: o estado depende do histórico, não só do valor atual, e por
isso **não é derivável**. `pacientes:45` é o exemplo mais claro, e o comentário `:42-44` explica o
porquê de forma exata: sobrescrever durante a digitação faria a resposta do termo antigo chegar
depois da tecla nova e **perder caractere** — "a tecla seguinte viraria `mai` em vez de `mari`".

O único que eu discutiria é `agenda:92`, onde a dependência é declarada lendo campos sem usá-los:

```ts
$effect(() => {
    data.appointments;   // lido para criar a dependência
    data.patients;
    live = null;
});
```

Funciona e está comentado. A alternativa idiomática seria derivar uma identidade de carga
(`const cargaId = $derived(data.appointments)`) e usar `{#key cargaId}` no subárvore — mas isso
remonta os componentes filhos, o que aqui é pior. **Fica como está; registro só para que a próxima
pessoa não "conserte" achando que é descuido.**

#### 3.1.2 O que não existe, e provavelmente devia

**`$effect.pre`: zero usos.** Há um lugar onde ele caberia:
[`+layout.svelte:41`](../web/src/routes/(app)/+layout.svelte) e `Modal:31`/`Drawer:45` movem o foco
**depois** do DOM atualizar — que é o correto para foco. Não achei caso que peça `pre`. Registro
como verificado-e-negativo, não como pendência.

**`$effect.root`: zero.** Correto — não há estado reativo criado fora de componente que precise de
escopo próprio; os quatro módulos `.svelte.ts` usam `$state` de módulo (§3.4).

**`onMount`: zero.** Tudo migrou para `$effect`, que é o caminho recomendado no Svelte 5.

### 3.2 As sete reações a `form` — mesma forma, sete escritas

| Rota | Guarda de identidade | Sucesso | Erro |
| --- | --- | --- | --- |
| `agenda:542` | **sim** (`ultimoForm`) | fecha modal + `toast(SUCESSO[action])` | toast, exceto criar/remarcar |
| `fila:255` | **sim** (`ultimoForm`) | navega/fecha + `toast(SUCESSO[action])` | fica no modal |
| `notificacoes:32` | não | — | toast |
| `pacientes/[id]:53` + `:64` | não (**dois efeitos separados**) | fecha modal | toast, exceto `grade` |
| `equipe:47` | não | `toast(toastText(action))` | toast só p/ `revoke`/`resend` |
| `tipos:44` | não | `toast(toastText(action))` | toast só p/ `archive`/`restore` |
| `excecoes:23` | não | toast por ternário inline | toast só p/ `delete` |

Duas coisas aqui.

**Primeira — a guarda tem história de crash, e ela está documentada duas vezes.**
[`fila:248-253`](../web/src/routes/(app)/fila/+page.svelte):

> Como `$state`, a atribuição embrulhava o objeto num PROXY, então a guarda `form === ultimoForm`
> era falsa para sempre: o efeito lia e escrevia o mesmo estado, estourava
> `effect_update_depth_exceeded` e derrubava a reatividade da tela inteira.

Isso é diagnóstico de primeira qualidade e o `let` simples é a correção certa. **As cinco rotas sem
guarda não estão quebradas** — os efeitos delas não leem estado que escrevem, então não há ciclo.
Mas nada no código diz isso, e a próxima pessoa que adicionar uma leitura reativa dentro de
`equipe:47` reabre o mesmo crash sem aviso.

**Segunda — é a mesma função escrita sete vezes.** Extração natural, em `forms.svelte.ts` (que já é
o dono desse assunto):

```ts
reagirAoForm(() => form, {
  sucesso: (r) => { … },              // roda uma vez por resultado NOVO
  erro:    (r) => toast(r.error ?? '…', 'error'),
  ignorarErroDe: ['criar', 'remarcar'] // as ações cujo erro fica dentro do modal
});
```

Absorve a guarda de identidade **para todas as sete**, apaga os dois `toastText` gêmeos
(`equipe:54`, `tipos:51`) e os dois `const SUCESSO` (`agenda:525`, `fila:242`) se o mapa virar
parâmetro. **7 call-sites.**

### 3.3 Estado, props e `$bindable`

**Fluxo props-down/events-up, sem vazamento.** Não achei um caso de `$state` mutável exposto para
fora do componente que o declara. `$bindable` aparece **4 vezes**, todas justificadas:
`Field:21` (`value`), `EncaixeCheckbox:6` (`checked`) — os dois são controles de formulário, o caso
canônico — e `PatientForm:39` / `ProfessionalForm:51` (`submitting`), onde a página precisa saber
que o form está em voo para travar o cabeçalho.

**O uso de `untrack` para semear estado editável é maduro e consistente.** **61 ocorrências em 15
arquivos** — 47 delas alimentando um `$state`, as outras 14 capturando um valor de referência
(`const editing = untrack(() => professional !== null)`, `ProfessionalForm:59`). Sempre no mesmo
molde:

```ts
// configuracoes/clinica/+page.svelte:18-20
let nome     = $state(untrack(() => data.clinic.nome));
let cnpj     = $state(untrack(() => maskCnpj(data.clinic.cnpj ?? '')));
let endereco = $state(untrack(() => data.clinic.endereco ?? ''));
```

É exatamente o idiom correto para "rascunho inicializado do servidor, depois independente" —
e é o que evita o `state_referenced_locally` sem desligar o aviso. Só 2 `svelte-ignore
state_referenced_locally` no repo inteiro.

**`$state.raw`: zero usos.** Há um candidato defensável —
[`fila/+page.svelte:118`](../web/src/routes/(app)/fila/+page.svelte),
`let slotsByEntry = $state<Record<string, Slot[]>>({})`, que é substituído inteiro a cada resposta
e nunca mutado em profundidade; `$state.raw` evitaria embrulhar N arrays em proxy. Ganho pequeno,
risco pequeno. **Registro como observação, não como achado** — não medi o custo real.

**`$derived.by`: 7 usos**, todos em blocos com laço ou acumulador que não cabem numa expressão
(`ListView:45`, `WeekView:43`, `MonthView:38`, `OfferSlotModal:103` e `:123`,
`PackageCreateModal:118` e `:216`). Uso correto — `$derived.by` para o que não é uma expressão, e
`$derived` (317 usos) para o resto.

### 3.4 Os módulos `.svelte.ts` — o ponto mais forte do capítulo

Quatro módulos com estado em runes fora de componente, e os quatro são bem desenhados:

- [`forms.svelte.ts`](../web/src/lib/forms.svelte.ts) (175 linhas) — `envio()` e `envioPorItem()`.
  Encapsula "POST em voo" com três variantes de chave (`submit`, `submitDinamico`,
  `submitPeloBotao`), e trata a armadilha que o doc 88 mediu: falha de **rede** não pode passar pelo
  `update()`, porque o `applyAction` trocaria a página inteira pela tela de erro e levaria junto os
  31 campos digitados. **34 call-sites via `SubmitButton`.**
- [`toast.svelte.ts`](../web/src/lib/toast.svelte.ts) — singleton, uma mensagem por vez.
- [`anuncio.svelte.ts`](../web/src/lib/anuncio.svelte.ts) — live region com limpa-e-escreve e
  coalescência de rajada. As duas armadilhas de `aria-live` estão resolvidas e documentadas.
- [`media.svelte.ts`](../web/src/lib/media.svelte.ts) — `matchMedia` reativo com getter e
  `onDestroy`, `false` no SSR.

Todos usam o padrão **getter em vez de exportar o `$state`** (`get emVoo() { return emVoo }`), que é
a forma correta de expor reatividade de módulo em Svelte 5. É por causa desses quatro que o D-3
(§2.3) é uma extração óbvia: o molde já existe.

**Uma ressalva, medida mas não explorada:** `toast.svelte.ts` mantém `$state` em **escopo de
módulo**, o que no servidor é estado compartilhado entre requisições. Na prática `toast()` só é
chamado de `$effect` e de handler de evento — caminhos exclusivamente de browser — então não há
vazamento hoje. Mas nada impede uma chamada de `load` amanhã. Vale um comentário no arquivo.

**Classes com runes (`class X { foo = $state() }`): zero.** Nenhum lugar pede — o estado do app é
funcional e por-tela. Verificado-e-negativo.

### 3.5 Contexto: zero usos, e o preço aparece no `Sidebar`

**`setContext`/`getContext`: 0 ocorrências no repositório.**

Na maior parte do app isso é acerto: a profundidade de props é rasa (rota → componente de área →
primitivo), e `$app/state` (22 usos) resolve o que seria contexto de roteamento.

O preço está concentrado num lugar. `Sidebar.svelte` lê **20 chaves de `page.data`**, cada uma com
um cast defensivo:

```ts
// shell/Sidebar.svelte
:87   const profs       = $derived((page.data.professionals as Professional[]  | undefined) ?? []);
:107  const patCounts   = $derived((page.data.counts as PatientCounts | undefined) ?? {…});
:128  const waitlist    = $derived((page.data.waitlist as Entry[] | undefined) ?? []);
:131  const filaCounts  = $derived((page.data.counts as WaitlistCounts | undefined) ?? …);
:145  const agendaHidden= $derived((page.data.hidden as string[] | undefined) ?? []);
…
```

Repare em `:107` e `:131`: **a mesma chave `counts` é lida como dois tipos diferentes**, dependendo
da rota. O TypeScript não pode ajudar — `page.data` é a união de todos os `load` e o cast é a única
saída. Não é `getContext` que resolve isso (o problema é o contrato, não o transporte); o que
resolveria é **um tipo discriminado por seção** em `lib/components/shell/nav.ts`, algo como
`type DadosDaSecao = { secao: 'pacientes'; counts: PatientCounts } | { secao: 'fila'; counts:
WaitlistCounts } | …`, com um único `as` na fronteira em vez de 20.

### 3.6 Snippets: composição de verdade, sem `{@html}`

**50 `{#snippet}` e 133 `{@render}`**, distribuídos em 26 arquivos. E — a checagem que importa —
**zero componentes recebem HTML ou string de marcação por prop**: as 12 props do tipo `Snippet` são
`children`, `footer`, `control` e afins.

`{@html}` aparece **uma vez** no `src/` inteiro, e é o uso legítimo: o JSON-LD da landing
([`routes/+page.svelte:112`](../web/src/routes/+page.svelte)), montado sobre
`JSON.stringify(...).replace(/</g, '\\u003c')` — que é exatamente a mitigação que um `<script>`
gerado por template exige (sem ela, um `</script>` vindo do dado fecharia a tag). Nenhuma marcação
de UI passa por ali.

O caso exemplar está em [`+layout.svelte:93-101`](../web/src/routes/(app)/+layout.svelte), e o
comentário explica exatamente por que o snippet é a solução certa:

> O cromo (rail + sidebar) num SNIPPET, e não escrito duas vezes. Ele aparece em dois lugares —
> fixo no desktop e dentro da gaveta no mobile — e cada prop nova precisava ser ligada nos dois.
> Foi assim que o bug do CNPJ passou […] o snippet **elimina a classe do bug**.

Onde um snippet ainda resolveria melhor: `AppointmentDrawer` (5 snippets, 1.034 linhas) já os usa,
mas as quatro tabelas responsivas do §2.4 repetem o par linha-desktop/cartão-mobile inline —
[`equipe/+page.svelte:80`](../web/src/routes/(app)/configuracoes/equipe/+page.svelte) já extraiu
`{#snippet rowActions(m)}` e o renderiza nas duas versões (`:165` mobile, `:201` desktop); as outras
três repetem os botões.

---

## 4. Código limpo e manutenibilidade

### 4.1 Ranking por linhas de código (descontando comentário)

A base é **densamente comentada** — 15% a 37% das linhas nos arquivos grandes — e ranquear por
`wc -l` cru superestima. Descontando comentários:

| Arquivo | total | comentário | **código** |
| --- | --- | --- | --- |
| `lib/components/agenda/AppointmentDrawer.svelte` | 1.034 | 153 | **881** |
| `routes/+page.svelte` (landing) | 821 | 36 | **785** |
| `lib/components/patients/PatientForm.svelte` | 823 | 91 | **732** |
| `lib/components/professionals/ProfessionalForm.svelte` | 754 | 44 | **710** |
| `lib/audit.ts` | 904 | 243 | 661 |
| `lib/agenda.ts` | 1.006 | 371 | 635 |
| `routes/(app)/fila/+page.svelte` | 605 | 69 | **536** |
| `routes/(app)/agenda/+page.svelte` | 712 | 183 | 529 |
| `lib/components/shell/Sidebar.svelte` | 596 | 68 | **528** |
| `lib/components/patients/PackageList.svelte` | 583 | 60 | 523 |
| `lib/components/patients/PackageCreateModal.svelte` | 578 | 61 | 517 |

**Os dois `lib/*.ts` grandes não são o problema.** `agenda.ts` tem 37% de comentário e é lógica
pura testada; `audit.ts` idem. Quem pede quebra são os `.svelte`:

1. **`ProfessionalForm` (710 de código, 44 de comentário)** — a pior razão comentário/código do
   grupo, e o menor teste (§4.7). Costura natural: D-1.
2. **`PatientForm` (732)** — mesma costura.
3. **`Sidebar` (528)** — costura natural por **seção**: `SidebarPacientes.svelte`,
   `SidebarFila.svelte`, … com o `sectionOf(pathname)` decidindo qual montar. Sete arquivos de ~70
   linhas em vez de um de 596, e cada um passa a poder declarar o seu próprio tipo de `page.data`
   (§3.5).
4. **`AppointmentDrawer` (881)** — o maior, mas o **mais bem defendido**: 1.084 linhas de teste, 67
   `it`, 112 `expect` (§4.7). Quebrar por abas (ficha / comunicação / participantes) é possível, mas
   o risco/benefício é pior que o dos três acima. **Deixaria por último.**
5. **`fila/+page.svelte` (536)** e **`agenda/+page.svelte` (529)** — ver §4.2.

### 4.2 Lógica pura presa em `.svelte`

O padrão do repo é bom: 41 módulos em `lib/*.ts` com 37 `.test.ts` ao lado, e a lógica de domínio
mora lá (`agenda-layout`, `scheduling-conflicts`, `waitlist`, `packages`, `audit`…). O que sobra
dentro de `.svelte` são estes blocos concretos:

| Bloco | Onde | Para onde iria |
| --- | --- | --- |
| `dragReschedule` — monta `FormData`, `deserialize`, decide entre conflito e toast | `agenda/+page.svelte:480-513` (34 linhas) | a decisão (`code === 'schedule_conflict' && canCreateEncaixe`) é pura → `lib/agenda-drag.ts`, que **já existe** e já tem `dropMinutes`/`passouLimiar` |
| `runCepLookup` + `onCepInput` | `PatientForm:221`, `ProfessionalForm:147` | `lib/cep.svelte.ts` (D-1) |
| `SECTIONS` / `totalKeys` / seção corrente / `goSec` | `PatientForm:333-360`, `ProfessionalForm:257-283` | `lib/form-secoes.ts` (D-1) |
| `search(q)` | `agenda:516`, `fila:108` | `lib/patient-search-client.ts` (D-4) |
| mapa `id → nome` de profissional | `pacientes:77`, `pacientes/[id]:80` | `lib/professionals.ts`, ao lado de `professionalName` |
| `toastText(action)` | `equipe:54`, `tipos:51` | some com `reagirAoForm` (§3.2) |
| `quando(iso)` × 5 | ver 93 §B-1 | `lib/format.ts` |
| `CHIP` / `COR` / `ESTADO` (mapas de tom por estado) | `PackageList:135`, `OccupancyBar:16`, `PackageSessionsModal:74` | ficam — são apresentação, e o dado que os alimenta já vem de `lib` |

O efeito colateral de tudo isso não é estético: **o gate de cobertura de 80% inclui `src/lib/**` e
`src/routes/**/*.ts`, e exclui `.svelte`** ([`vite.config.ts:85`](../web/vite.config.ts)). Cada
função pura que fica num `.svelte` sai do gate e só é exercitada indiretamente por teste de
componente — quando há.

### 4.3 Duplicação entre `lib/*.ts` e `lib/server/*.ts`

**Não encontrei duplicação de formatação, parsing ou máscara entre as duas camadas.** Verifiquei os
suspeitos habituais: `telefone.ts`, `cnpj.ts`, `masks.ts`, `format.ts` existem **uma vez** e são
importados dos dois lados. `PreviewResult` é declarado em `lib/packages.ts:58` e **importado** por
`lib/server/packages.ts:4` — que é o desenho certo.

Uma colisão de nome vale registro: **`Slot` existe duas vezes com significados diferentes** —
`lib/agenda-layout.ts:28` (faixa de layout na grade) e `lib/waitlist.ts:62` (vaga oferecível). Não
há bug porque nunca são importados no mesmo arquivo, mas o nome é o mesmo em dois domínios e isso
é uma armadilha de leitura.

### 4.4 Tipagem: excelente onde o compilador alcança

**Zero `any`. Zero `@ts-ignore`, `@ts-expect-error`, `@ts-nocheck`, `eslint-disable`.** Numa base de
~17k linhas de `.svelte` mais 6,8k de `lib`, isso é raro e é o item mais forte deste capítulo.

**Só 6 declarações de tipo dentro de `.svelte`** — `Sessao`, `Prof`, `Drag`, `Upcoming`, `DupMatch`,
`Campo`. Os tipos de domínio moram em `lib/` e são importados (`type Appointment`,
`type AgendaProfessional`… de `$lib/agenda`).

Os **280 casts `as X`** em `.svelte` se concentram onde o TypeScript de fato não alcança:

| Arquivo | casts | Natureza |
| --- | --- | --- |
| `shell/Sidebar.svelte` | 31 | `page.data` — §3.5, o caso estrutural |
| `agenda/+page.svelte` | 15 | `ActionResult`, `RealtimeConfig`, resposta de `fetch` |
| `agenda/AppointmentDrawer.svelte` | 14 | `form.data` de action |
| `routes/+page.svelte` | 13 | landing, `style` inline |
| `agenda/DayGrid.svelte` | 13 | eventos de ponteiro / `HTMLElement` |

### 4.5 O vão de contrato: 16 `fetch` do browser, zero tipados contra o servidor

Este é o achado mais acionável do capítulo. O app tem 16 `fetch` chamados do browser, e **cada um
declara a forma da resposta por conta própria**:

```ts
// PackageSessionsModal.svelte:47      .then((d: { sessions: Sessao[] }) => …)
// PackageCreateModal.svelte:185       .then((d: { preview: PreviewResult | null }) => …)
// fila/+page.svelte:130               .then((d: { slots_by_entry?: Record<string, Slot[]> }) => …)
// OfferSlotModal.svelte:81            .then((d: { slots?: Slot[] }) => …)
// agenda/+page.svelte:518             return (await res.json()) as SearchResult;
```

O caso que fecha o argumento é o `PackageSessionsModal`. Ele declara localmente:

```ts
// lib/components/patients/PackageSessionsModal.svelte:16
type Sessao = {
    attendance_id: string;
    appointment_id: string;
    starts_at: string;
    estado: 'concluida' | 'falta' | 'segurada' | 'proxima' | 'agendada';
};
```

E o endpoint que ele consome —
`routes/(app)/pacientes/[id]/pacotes/[pkg]/sessoes/+server.ts` — devolve
`PackageSession[]`, declarado em [`lib/server/packages.ts:182`](../web/src/lib/server/packages.ts):

```ts
export interface PackageSession {
    attendance_id: string;
    appointment_id: string;
    starts_at: string;
    estado: 'concluida' | 'falta' | 'segurada' | 'proxima' | 'agendada';
}
```

**Campo por campo, união por união, o mesmo tipo escrito duas vezes** — uma de cada lado de uma
fronteira que o TypeScript atravessaria de graça. Se o backend acrescentar um valor a `estado`, o
servidor compila, o componente compila, e o `switch` do componente cai no default silenciosamente.

**O que paga.** Mover os tipos de resposta dos endpoints internos para `lib/<dominio>.ts` (que é
importável dos dois lados — `PreviewResult` já faz isso) e importá-los no componente. Não é
refatoração: é apagar a segunda declaração e trocar por um `import type`. Cinco lugares.

### 4.6 Erro e carregamento: filosofia consistente, vocabulário não

**A filosofia é uniforme e está certa.** Todo `fetch` auxiliar degrada para vazio em vez de estourar
— `{ candidates: [] }`, `{ slots: [] }`, `{ patients: [], total: 0 }` — e o único caminho que
**reporta** (`reportar('realtime:token', e)`) é o do tempo real, justamente porque a falha ali é
invisível ao usuário. Isso está documentado nos três lugares e é uma decisão, não um acidente.

O erro de **submissão** é ainda melhor: `forms.svelte.ts` centraliza `ERRO_DE_REDE` e a regra de não
chamar `update()` numa falha de rede — com o incidente medido (doc 88, A-10) escrito no arquivo.

**O vocabulário é que não é uniforme.** Seis nomes para "está carregando", em escopos diferentes:

| Nome | Origem | Onde |
| --- | --- | --- |
| `emVoo` | `forms.svelte.ts` (o padrão) | 34 call-sites via `SubmitButton` |
| `submitting` | à mão | `comecar:10`, `AuthForm:25`, `PatientForm`/`ProfessionalForm` (`$bindable`) |
| `loading` | à mão | `OfferSlotModal:52` |
| `carregando` | à mão | 4 lugares |
| `enviando` | à mão | `PatientAttachments:102` (upload com progresso — caso próprio) |
| `previewing` | à mão | `PackageCreateModal:149` |

E — a lacuna real — **o app não tem nenhum componente de skeleton**. Onde o dado chega por `fetch`
depois do render (timeline do drawer, vagas da fila, sessões do pacote, prévia do pacote), o estado
intermediário é texto ou nada. Não é bug; é uma decisão que ninguém tomou explicitamente.

### 4.7 Testes: profundidade real, com dois vãos claros

O padrão é **teste de comportamento, não de fumaça**. Os nomes dos `it` são asserções de domínio
("`CPF com DV errado desabilita e o rodapé diz o porquê`", "`a DICA neutra não é alert (senão o
leitor de tela a anunciaria a cada toque)`"), não "renderiza sem erro".

Ranking dos componentes ≥150 linhas por razão linhas-de-teste / linhas-de-componente:

| Componente | comp. | teste | `it` | `expect` | razão |
| --- | --- | --- | --- | --- | --- |
| `agenda/AppointmentBlock` | 306 | 447 | 36 | 50 | **1,46** |
| `agenda/MessageTimeline` | 172 | 267 | 14 | 26 | 1,55 |
| `agenda/AppointmentDrawer` | 1.034 | 1.084 | **67** | **112** | 1,05 |
| `patients/PackageCreateModal` | 578 | 441 | 22 | 45 | 0,76 |
| `patients/PatientForm` | 823 | 389 | 25 | 53 | 0,47 |
| `patients/PackageList` | 583 | 279 | 26 | 46 | 0,48 |
| `shell/Sidebar` | 596 | 296 | 25 | 42 | 0,50 |
| `patients/PatientAttachments` | 452 | 313 | 17 | 46 | 0,69 |
| `agenda/DayGrid` | 517 | 318 | 23 | 34 | 0,62 |
| `agenda/RescheduleModal` | 163 | 68 | **3** | 7 | 0,42 |
| `members/MemberModal` | 154 | 54 | **3** | 10 | **0,35** |
| **`professionals/ProfessionalForm`** | **754** | **146** | **10** | **22** | **0,19** |

**O vão é o `ProfessionalForm`**, e a comparação com o seu gêmeo prova que não é "esse componente é
simples": `PatientForm` (823 linhas) tem **25 `it`**, `ProfessionalForm` (754) tem **10**. Rodando
os títulos lado a lado, o que falta no de profissional são justamente as classes que o de paciente
cobre:

- validação de campo (`CPF com DV errado`, `e-mail sem forma de e-mail`, `nascimento no futuro`) —
  **zero equivalentes**;
- estado de erro do servidor (`o erro do servidor é anunciado e aparece em QUALQUER largura`) —
  ausente;
- semântica de a11y (`a DICA neutra não é alert`) — ausente.

Os dois compartilham `runCepLookup` e o esqueleto de seções (D-1) — então metade dos testes de um
prova o código do outro **por cópia, não por reúso**. Extrair (D-1) e testar a extração uma vez
resolve os dois vãos de uma vez.

Menções honrosas do outro lado: `AppointmentDrawer` com 67 `it` para 881 linhas de código é a
melhor cobertura de componente do repo, e é o maior arquivo — a ordem certa.

**Sete componentes sem teste** (93 §B-10): `Seo`, `AgendaEmptyState`, `ConflictErrorBox`,
`EncaixeCheckbox`, `OccupancyBar`, `FlowArt`, `StatusBadge`. Três deles (`AgendaEmptyState` 4 usos,
`ConflictErrorBox` 5, `EncaixeCheckbox` 3) são **reusados**, o que os torna os mais caros da lista.

---

## 5. Ordem sugerida — custo/efeito

1. **§4.5 — importar os tipos de resposta em vez de redeclará-los.** Cinco `import type`, zero
   lógica nova, e fecha o único buraco de contrato que o TypeScript resolveria de graça.
2. **D-3 (§2.3) — `usarTokenRealtime()` em `lib/realtime-token.svelte.ts`.** ~45 linhas removidas de
   3 arquivos; o molde (`media.svelte.ts`) já existe.
3. **D-2 (§2.3) — `components/Paginacao.svelte`.** 4 call-sites, apaga 4 `navBtn`.
4. **§3.2 — `reagirAoForm()` em `forms.svelte.ts`.** 7 call-sites; leva junto a guarda de identidade
   que hoje só duas rotas têm, e apaga os dois `toastText` gêmeos.
5. **D-4 e D-5 — `buscarPacientes()` e `professionalNameMap()`.** 2 call-sites cada, triviais.
6. **§4.7 — cobrir o `ProfessionalForm`.** É o único vão real de teste, e o `PatientForm` já dá o
   roteiro pronto dos casos.
7. **`EstadoVazio` (§2.4)** — ~16 call-sites, o maior alcance por linha escrita depois do item 1.
8. **`Badge` (§2.4)** — funde `RoleBadge`/`StatusBadge`/`PriorityBadge` e ~15 inline. **Depende de
   ter escala de tamanho** (93 §M-1/M-2), senão congela as grafias atuais em código.
9. **D-1 (§2.3) — o `FichaShell` e as duas extrações de lógica.** A maior e a mais valiosa: ~290
   linhas unificadas, duas funções puras entram no gate de cobertura, e o vão do item 6 fecha por
   construção. Fazer **depois** de 1–5, que são baratos e reduzem o ruído do diff.
10. **`Sidebar` em sete arquivos (§4.1)** — leva junto o tipo discriminado de `page.data` (§3.5) e os
    20 casts somem.

**Não fazer:** quebrar o `AppointmentDrawer` (a cobertura é a melhor do repo, o risco não paga) e
"consertar" os sete `$effect` de reset (§3.1.1) — eles estão certos.

---

## 6. O que este doc não mediu

- **Nada foi executado.** Sem `npm run test:unit`, sem browser. As razões de teste são de contagem
  estática (`it`/`expect`), não de cobertura medida por linha — o `--coverage` daria número melhor
  para §4.7 e não foi rodado.
- **A complexidade é "aparente"**, medida por linhas de código descontando comentário. Não rodei
  complexidade ciclomática nem profundidade de aninhamento.
- **Os endpoints `/agenda/pacientes` e `/fila/pacientes` (D-4)** não foram comparados no servidor —
  disse que "provavelmente querem ser um só" sem verificar se divergem.
- **Não avaliei `lib/server/*.ts` por dentro.** O capítulo 4.3 só procurou duplicação **entre**
  camadas; a qualidade interna dos 23 módulos do BFF é outra auditoria.
- **`$state.raw` em `slotsByEntry` (§3.3)** é hipótese, não medição: não perfilei o custo de proxy.
- **O `routes/+page.svelte` (785 linhas de código, o 2º maior)** ficou de fora do ranking de quebra
  por ser a landing — superfície de marketing, gerada a partir do protótipo, com regras próprias
  (93 §2.1).
