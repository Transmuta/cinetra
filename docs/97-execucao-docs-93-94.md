# 97 — Execução das auditorias 93 e 94: o que foi feito, o que mudou de aparência e o que ficou

**Data:** 2026-07-30 · **Escopo:** os achados dos docs [93](93-auditoria-design-system-web.md)
(design system) e [94](94-auditoria-reuso-e-idioms-svelte.md) (reúso e idioms) · **Natureza:**
relatório de execução. 5 commits, 135 arquivos, +5.852/−2.144.

**Gates ao fim:** `svelte-check` 0 erros e 0 avisos · `npm run coverage` 204 arquivos, **2.409
testes**, 93,01% (piso 80) · `npm run build` verde. Baseline antes de começar: 186 arquivos, 2.285
testes.

**As quatro decisões humanas** que abriram o trabalho, e que valem por escrito porque mudam o
critério de tudo o que veio depois:

| Pergunta | Decisão |
| --- | --- |
| Até onde ir? | **Tudo**, incluindo as quebras grandes (D-1 e o `Sidebar`) |
| `hover:text-white` em 2,71:1 | **Registrar como débito**, não consertar — é a mesma cor da ADR-020 |
| `initials("Dra. Ana Silva")` | **`AS`** — o título não identifica ninguém |
| Escala tipográfica | **Normalizar** para poucos degraus, aceitando mexer em pixels |

---

## 1. O que mudou de APARÊNCIA

Esta seção vem primeiro porque é a única cujo efeito nenhum teste mede. Tudo aqui foi coberto pela
decisão "normalizar", mas é decisão de desenho e merece olho na tela antes de ir para produção.

| O quê | Antes | Depois |
| --- | --- | --- |
| Controles nativos no tema escuro | ícone/painel do sistema em modo CLARO (1,15:1) | acompanham o tema |
| Tamanhos de fonte | 22 valores | 7 degraus — alguns textos mudam 0,5–1px |
| Raios | 13 valores | 4 degraus — alguns cantos mudam até 2px (14px → 12px nos cartões) |
| Campos dos formulários grandes | borda sutil, padding 10px, placeholder cinza da UA | borda densa, 11px, `placeholder:text-faint` |
| Botão primário | 23 instâncias em 15 grafias, 4 sem hover, nenhuma com transição | 4 variantes, 2 tamanhos, todas com hover e transição |
| Vazio ilustrado | 5 geometrias | 1, com título em 13,5px (era 14px em duas telas) |
| `RoleBadge` do papel `profissional` | superfície neutra + texto azul | tom `info` completo |
| `/perfil` | dois `<h1>` | um `<h1>` (o do topbar) + `<h2>` |

**Os 52 placeholders** merecem nota: eles herdavam o `#757575` fixo da UA porque o `inputCls`
paralelo não declarava cor. Agora são `text-faint`, que é medido.

---

## 2. Os achados de ALTO — todos fechados

**A-1 · `color-scheme`.** Três linhas de CSS. O que ele alcança é o que os tokens `--mv-*` não
conseguem repintar porque mora no shadow-DOM da UA: 9 `type="date"`, 6 `type="time"`, 16
`<select>`, 3 `<textarea>` e o realce de autofill. Travado em `tema-escopo.test.ts`.

**A-3 · O diálogo artesanal.** `PatientAttachments` agora compõe `Modal`. Saiu código, não entrou.
Os três testes que escrevi antes do conserto — role, Esc, foco devolvido — falharam nos três, que
é a prova de que o vão era real. O diálogo entrou na varredura do axe com guarda que **diz em voz
alta quando pula** (só há botão de renomear se houver anexo semeado, e semear anexo depende do
storage).

**A-4 · `initials()`.** A função local de `/relatorios` sumiu; `format.ts` passa a cortar o título.
O ponto é obrigatório no padrão — sem ele, "Draco Alves" perderia a sílaba, e isso tem teste.

**A-2 · O hover em 2,71:1.** Não consertado, por decisão. Registrado no **D-17** (que agora se
chama "o branco sobre o sage", porque `--mv-primary` e `--mv-accent-solid` são o mesmo `#7fa59a`),
e o filtro de isenção do gate virou `semExcecaoDoSage`. Registrado também o que fazer quando o
D-17 for pago: `--mv-accent-solid` precisa escurecer junto, senão o hover fica reprovando sozinho.

---

## 3. O que passou a ser medido — três instrumentos novos

O doc 93 fechou dizendo que **nenhum dos seis gates olhava para consistência de dimensão**, e o
94 que o contrato entre BFF e browser não era verificado. Os três arquivos abaixo são a resposta.

### `cor-crua.test.ts`

O `contraste.test.ts` mede pares de TOKEN, então cor escrita à mão é invisível para ele **por
construção**. Foi assim que `#9a6a05` sobreviveu 194 linhas abaixo do comentário que dizia tê-lo
removido, e que o avatar do usuário logado ficou com `#0072B2` cravado enquanto `avatar.ts`
existia. O tripwire varre o app interno, isenta a família de marca com a razão escrita, e tem um
caso que prova que ele está lendo alguma coisa — guarda contra o pior desfecho, que é a lista
vazia por o scanner não estar varrendo nada.

Ele acusou exatamente os cinco previstos. Os cinco foram pagos.

### `camadas.test.ts`

Aqui a medição mudou o desenho: **`z-index` não é namespace temável no Tailwind v4**. Testei —
`--z-index-modal: 50` no `@theme` não gera classe nenhuma. E o modo de falha é o pior possível:
utilitário desconhecido não é erro de build nem de `svelte-check`, ele só deixa de existir no CSS
e o elemento cai para `z-index: auto`. As camadas vieram por `@utility`, e o teste foi **validado
por mutação** — troquei o `z-toast` do Toast por um `z-popover` inexistente e ele acusou.

### `dimensao.test.ts`

Duas travas por escala: que os degraus subam, e que valor arbitrário não volte. A segunda é a que
importa — sem ela a escala vira sugestão e o próximo componente copia o `rounded-[14px]` do
vizinho.

Além dos testes, conferi as 11 classes novas **no CSS construído**, não só no código: elas estão
lá e a cadeia `.rounded-cartao → var(--mv-radius-cartao) → 12px` resolve.

---

## 4. As extrações — o que cada uma unificou

| Extração | O que provava a cópia | Alcance |
| --- | --- | --- |
| `reagirAoForm` | 7 reações a `form` em 7 formatos; **só 2 tinham a guarda de identidade** | 7 call-sites |
| `Paginacao` | a MESMA string de 200 caracteres (`navBtn`) nos 4 arquivos | 4 |
| `EstadoVazio` | 5 geometrias para o mesmo papel | 5 |
| `usarTokenRealtime` | 3 blocos verbatim; **só o comentário mudava** | 3 |
| `data-hora.ts` | 5 `quando()` (2 byte-idênticas) + 3 listas de dia da semana com 3 nomes | 5 + 3 |
| `FichaShell` + `cep.svelte.ts` + `form-secoes.ts` | **a linha 3 dos dois arquivos era o mesmo comentário** | 1.577 → 700+633+178 |
| `Sidebar` → 8 arquivos | 20 casts de `page.data`, `counts` lido como 2 tipos | 596 → 89 + 8 arquivos; 20 casts → 7 |
| `Button` | 23 instâncias em 15 grafias | 1 → 15 call-sites |
| `Badge` | 3 componentes, 3 geometrias, base zero compartilhada | 2 componentes compõem |
| `buscarPacientes` / `professionalNameMap` | idênticas a menos da URL e do cast | 2 + 2 |

**Duas coisas ficaram DE FORA de propósito**, e vale registrar por quê:

- **`StatusBadge` não entrou no `Badge`.** Ele não é pílula — é ponto + rótulo, sem fundo. Forçá-lo
  daria uma flag booleana que troca a geometria inteira, que é o antipadrão que esta base não tem
  em lugar nenhum (doc 94 §2.5).
- **`SubmitButton` continua existindo.** O `Button` absorveu o `emVoo` para o caso comum, mas os
  ~28 botões de visual próprio (só-ícone, linha de tabela, chip) seguem nele, que explicitamente
  não impõe visual.

---

## 5. Onde a medição me corrigiu

Três vezes, e as três valem mais que os achados:

**Os tokens órfãos (§M-7).** Removi os quatro e o `contraste.test.ts` caiu. `--color-accent-hover`
e `--color-success-solid` não são órfãos no sentido que importa: são membros de FAMÍLIAS que ele
mede por inteiro (o par solid/hover do acento; os quatro fundos semânticos + `on-solid`).
Restaurados. Saíram só `--shadow-accent` e `--shadow-card`.

O `--shadow-card` era a única sombra que respondia ao tema, desenhada de propósito, e **nenhum dos
133 cartões a aplicava**. Foi removida em vez de aplicada porque aplicar é decisão de DESENHO com
133 cartões na mesa, não arrumação — o valor está no comentário do `app.css` para quem quiser
retomar.

**A folga do scroll-spy.** Escrevendo o teste de `secaoCorrente` descobri que eu tinha entendido
ao contrário: os 56px são a altura do cabeçalho fixo e fazem a seção virar ativa **antes** de
encostar no topo, não depois. O comentário estava errado no meu texto, não no código original.

**`PackageSession` estava escrito TRÊS vezes**, não duas como o doc 94 dizia — `lib/packages.ts`,
`lib/server/packages.ts` e o `type Sessao` local do modal.

---

## 6. O que NÃO foi feito, e por quê

- **Nada foi aberto no browser** além da sonda de `color-scheme` que já estava no doc 93. As
  mudanças de aparência da §1 pedem olho na tela — em especial os campos dos formulários grandes
  (borda densa) e os cartões (14px → 12px).
- **O e2e não rodou.** `a11y-interno.spec.ts` mudou em dois pontos (o filtro `semExcecaoDoSage` e o
  terceiro diálogo) e nenhum foi executado: precisa da stack de pé com dado semeado.
- **B-12 (a faixa 768–1023px)** continua sem medição. O cromo colapsa em `lg:` e as tabelas em
  `md:`, então entre 768 e 1023px a tela fica sem sidebar **e** com a tabela em modo desktop. É uma
  sonda de cinco minutos no browser e não foi feita.
- **B-7 (transições)** ficou como está: 201 utilitários `hover:` para 24 `transition-*`. É decisão
  de desenho ("interface administrativa, resposta imediata") e não achado — o `Button` novo tem
  transição, o que aumenta a assimetria em vez de resolvê-la.
- **B-8 (17 tamanhos de ícone em 254 usos)** não foi tocado. É o mesmo diagnóstico da tipografia em
  escala menor, e teria sido a quarta migração mecânica do dia.
- **Os 121 `<button>` crus restantes.** O `Button` foi de 1 para 15 call-sites migrando a família
  primária; o resto tem visual próprio e migrar em bloco congelaria decisões que ninguém tomou.
- **Os 8 arquivos novos do `sidebar/` não têm `.test.ts` próprio** — mas os 25 testes de
  `Sidebar.svelte.test.ts` continuam passando sem uma linha alterada, e é justamente isso que
  prova que a quebra preservou o comportamento. O teste ficou no componente composto; não é vão de
  cobertura, é cobertura no nível de cima.
- **Um tripwire de token órfão** seria o quarto instrumento natural (varrer `@theme` e cobrar uso).
  Não foi escrito: alguns tokens são usados dinamicamente (`var(--color-{tone})` no `ListView`), o
  que exige uma lista de isenção com justificativa — mais desenho do que sobrou de sessão. Fica
  como sugestão.

---

## 7. Ordem dos commits

1. `4516bb8` — os três furos que os gates não viam + o tripwire de cor crua
2. `13955c8` — sete formatos, quatro rodapés e cinco vazios viram um de cada
3. `318e758` — a camada de dimensão passa a existir + os dois gates novos
4. `8203eec` — os dois cadastros gêmeos compartilham o esqueleto
5. `db2a0a1` — sete barras laterais num arquivo viram sete arquivos

A ordem não foi arbitrária: bug antes de estrutura, estrutura antes de estética, e **cobertura
antes da quebra grande** — o vão de teste do `ProfessionalForm` (10 `it` para 754 linhas) foi
fechado ANTES do `FichaShell`, justamente para haver rede na hora de mexer.
