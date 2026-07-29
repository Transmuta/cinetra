# 76 — Acessibilidade: a auditoria do AN-08

**Data:** 2026-07-29 · **Frente:** `AN-08` (doc 64, decisão **D8**: auditar → consertar → só
então o gate no CI, já verde) · **Escopo:** teclado, foco, contraste — o que o HOM-028 apontou
como "em zero". Mobile ficou de fora (entrou por outros caminhos, doc 64 §1c).

## 1. Método

Três varreduras, porque uma só não cobre:

1. **axe-core no browser real** (`web/e2e/a11y-audit.spec.ts`, novo — usa `@axe-core/playwright`,
   instalado como devDependency porque é a mesma ferramenta do gate futuro). Nesta rodada cobriu
   as páginas **públicas** (`/`, `/entrar`, `/criar-conta`); as internas ficaram bloqueadas — ver
   o achado de ambiente em [§4](#4-o-achado-que-não-é-de-a11y-o-login-de-produção-quebrado);
2. **contraste pelos tokens** — o app inteiro pinta com meia dúzia de pares (`app.css`), então
   medir os pares vale por medir todas as telas. Script de razão WCAG sobre os valores dos dois
   temas;
3. **inspeção de teclado/foco** — os `svelte-ignore a11y_*` do repo (achados autodeclarados),
   os shells de diálogo (`Modal`/`Drawer`/`ConfirmDialog`) e os caminhos só-de-mouse.

## 2. Consertado nesta rodada

| # | Achado | Conserto | Prova |
| --- | --- | --- | --- |
| 1 | Divisor "ou" do login a **2,1:1** (`#B0AA9C` sobre `#F6F4EF`) — axe `serious` | `#696456` (5,4:1) | axe re-run limpo |
| 2 | "Avaliação · Dr. Rafael" da landing a **4,49:1** (por um fio) | `#616870` (5,0:1) | idem |
| 3 | Badge **ENCAIXE** branco sobre âmbar a **2,0:1** (10px bold — não é "large text") | texto escuro FIXO `#161a1e` (8,6:1) no drawer e na Lista; fixo porque o âmbar não muda no tema escuro e `text-ink` inverteria | — |
| 4 | **Diálogos sem gestão de foco** (WCAG 2.4.3): abrir Modal/Drawer não movia o foco (Tab passeava pela tela de trás do overlay), fechar não devolvia ao gatilho | `tabindex="-1"` + foco no abrir + devolução no fechar, nos dois shells — herda para todo modal/drawer/confirm do app | testes de regressão em `Modal.svelte.test.ts` e `Drawer.svelte.test.ts` |

O que já estava certo e a auditoria confirmou: `role="dialog"` + `aria-modal` + Esc nos dois
shells (com a guarda de Esc-duplo drawer×modal); rótulos `<label>` envolvendo inputs no
login/fichas; `aria-label` nos botões ícone-só; a legenda da agenda (AN-01) com texto, não só cor.

## 3. A lista aberta — decisões e pendências

Por ordem de dano. Os três primeiros são **decisões de paleta** (mexem no app inteiro; não
mudei tokens por conta própria — a AN-01 acabou de calibrar essas telas a olho):

1. 🔴 **`--mv-faint` reprova para texto pequeno nos dois temas**: 2,96–3,15:1 no claro,
   3,48–3,74 no escuro (piso AA de texto normal é 4,5). É o token mais usado do app para
   metadados de 11–12px. Opções: escurecer o token (proposta: alvo ≥4,5 sobre `surface2`, algo
   como `#6e7680` no claro), ou reclassificar `faint` como "só para ≥18px/14px-bold" e migrar
   os usos pequenos para `muted` (5,5:1);
2. 🔴 **branco sobre `teal_solid` a 2,57:1** — chips de vaga (ABRIU), botões teal sólidos.
   Proposta: texto escuro sobre teal (como se fez no âmbar), ou um teal-escuro para superfícies
   com texto branco;
3. 🟡 **badges brancas sobre `danger`/`success`/`info`** (3,3–3,9:1 em 10,5px bold — abaixo do
   piso porque bold só vira "large" a 14pt) — inclui a `PriorityBadge` da fila. Mesma decisão
   do item 2; **`warning` já foi consertado** (era o pior, 2,0);
4. 🟡 `teal_text` sobre `teal_subtle` a **4,46:1** — um passo de escurecimento resolve;
5. 🟡 **agenda sem caminho de teclado para criar**: o clique-na-célula é `div onclick`
   (`DayGrid:412`, suprimido com `svelte-ignore`), e o arraste é só ponteiro. Proposta barata:
   botão "Novo agendamento" no `AgendaNav` (abre o mesmo modal, sem preset de hora);
6. 🟡 **focus trap incompleto**: o foco agora ENTRA e VOLTA, mas Tab ainda sai do diálogo por
   trás (o conserto §2.4 é o passo 1 de 2);
7. ⚪ **skip link ausente** (pular para o conteúdo — o rail tem ~10 tabs antes do main);
8. ⚪ `PatientAttachments`: drop-zone com interação em elemento não-interativo + `autofocus`
   (os dois suprimidos com `svelte-ignore`) — dar caminho de teclado ao upload (já existe o
   input de arquivo; conferir a ordem);
9. ⚪ **zoom 200% e páginas internas no axe**: não medidos nesta rodada — rodar a spec
   `a11y-audit` com as páginas autenticadas quando a caixa de dev voltar (§4) e navegar as 5
   telas principais a 200%;
10. **O gate (D8, passo final)**: quando 1–4 estiverem decididos e consertados, a asserção do
    spec vira `expect(violations).toEqual([])` e entra no CI.

## 4. O achado que não é de a11y: o login de produção quebrado

A varredura autenticada morreu no login — e o motivo era um **bug latente de produção**: com
`RESEND_API_KEY` no ambiente, o `runtime.exs` aponta o Swoosh para `Swoosh.ApiClient.Finch`,
mas **ninguém subia o pool `Swoosh.Finch`** na árvore de supervisão. Primeiro magic link com a
chave ligada → `(ArgumentError) unknown registry: Swoosh.Finch` → **500 — login inteiro
quebrado** em qualquer ambiente com e-mail real. Nunca doeu antes porque dev/teste usam o
adapter Local/Test, que não passa pelo cliente HTTP.

Consertado (`{Finch, name: Swoosh.Finch}` no `application.ex`) com regressão em
[`swoosh_finch_test.exs`](../api/test/api/swoosh_finch_test.exs).

**Aviso de ambiente que fica**: com `RESEND_API_KEY` no `.env` de dev, o mailer real assume e
`/dev/mailbox` fica vazio — **os e2e autenticados não skipam, quebram por timeout** esperando
um magic link que foi para o Resend. Quem for rodar `npm run test:e2e` precisa tirar a chave
do ambiente (ou os e2e ganham essa guarda).
