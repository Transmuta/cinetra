# 51 — Notificações: limpar a caixa, abas e o contador

Complemento do [doc 31](31-notificacoes.md) (a caixa in-app) e do [doc 44](44-onda-4-notificacoes.md)
(a Onda 4, que a paginou e indexou). Entregue em 2026-07-27.

## O pedido, e o que dele já existia

O pedido foi "limpar todas, ler todas e contador no menu de não lidas". Medido no código antes de
escrever qualquer coisa, **dois dos três já existiam**:

| Pedido | Estado antes |
| --- | --- |
| ler todas | **existia** — botão "Marcar todas como lidas" → `POST /api/notifications/read-all` → `mark_all_read/1` (um `UPDATE`, #53) |
| contador de não lidas | **existia** — badge no sino do rail, de `unread_count/1` pelo índice parcial, com cap visual `9+` |
| limpar todas | **não existia** — o recurso não tinha ação de destroy nenhuma; a única remoção era a poda por cron (90/365 dias) |

Então o trabalho real foi: **construir o limpar**, e tornar os outros dois mais achaveis — o "ler
todas" e o contador ficavam só no cabeçalho e no rail, sem um lugar na tela que dissesse "estas
são as não lidas".

## Decisões

* **D1 — limpar apaga tudo, lidas e não lidas.** Não "só as lidas", nem arquivamento com
  `dismissed_at`. Uma notificação é um aviso, não um registro de domínio: o que aconteceu continua
  na agenda e na trilha de auditoria, que ninguém apaga por aqui. Sem lixeira e sem desfazer — por
  isso a confirmação (`ConfirmDialog`) é obrigatória.
* **D2 — as ações ficam na página, não num popover do sino.** O sino continua sendo link. Evita um
  componente novo (painel + endpoint de preview) para uma tela que já existe e já é o destino.
* **D3 — o badge continua com cap `9+`.** É o padrão do protótipo e o que cabe no rail de 56 px.
* **D4 — o filtro é aplicado no servidor.** `?filtro=nao-lidas` na URL vira `?unread=1` na API.
  Filtrar escondendo linha no browser quebraria a paginação: a página chegaria com 20 e exibiria 3.
* **D5 — o filtro mora na SIDEBAR, não no corpo.** Nasceu como abas no corpo da página e foi movido
  na revisão seguinte: é o mesmo papel que `?status=` tem em Profissionais, `?filter=` em Pacientes
  e `?prio=` na Fila, e todos moram na sidebar contextual. Notificações virou `Section` própria
  (`sectionOf`) — **sem item de rail**, porque o acesso continua sendo o sino.
* **D6 — cada linha não lida ganha o seu botão de "marcar lida".** Antes só dava para marcar
  *abrindo* a notificação, o que arrastava a pessoa para outra tela. São dois `<form>` irmãos para
  a mesma action (botão dentro de botão é HTML inválido).

## O que foi construído

### Backend

* `destroy :clear` em `Api.Notifications.Notification` — **sem hook nenhum**, de propósito: é o que
  deixa o `Ash.bulk_destroy!` ir pelo caminho atômico (um `DELETE`) e a policy filter-check virar
  cláusula do `WHERE`. Mesmo desenho do `mark_all_read`, e pela mesma razão documentada lá.
* `policy action_type(:destroy)` com `recipient_id == ^actor(:id)` — o recorte que separa "esvaziei
  a minha caixa" de "apaguei a do colega".
* `Api.Notifications.clear_all/1` — `COUNT` + `DELETE` dentro de `in_clinic`, partindo da read
  `:read` (a `:inbox` traz um `sort` que não serve a um DELETE).
* `DELETE /api/notifications` → `%{cleared: n, unread: 0}`. **Verbo é contrato**: DELETE na coleção,
  e não um `POST /clear-all` ao lado do `read-all`, porque a coleção inteira do dono deixa de
  existir. O `read-all` é POST por ser transição de estado, não remoção.

### Frontend

* `clearAllNotifications` no BFF e a action `clearAll` na página.
* Filtro **Todas / Não lidas (N)** na **sidebar contextual** (`Sidebar.svelte`, ramo
  `section === 'notificacoes'`), como Profissionais/Pacientes/Fila. O número das não lidas vem do
  **layout** (`page.data.unread`) — o mesmo que alimenta o badge do sino, para que os dois nunca
  divirjam. "Todas" fica **sem número**: a API não conta o total de propósito (`count: false`), e
  um número que contasse só a página aberta seria pior que nenhum (mesma regra do `hasProfCounts`).
* Botão **"Limpar tudo"** com `ConfirmDialog` + form escondido disparado por `requestSubmit()`
  (molde do "sair de todos os dispositivos" do `/perfil`).
* Botão **✓ por linha** nas não lidas: marca lida sem navegar. Sem callback de `enhance` de
  propósito — o padrão do SvelteKit já revalida tudo, o que tira o realce e derruba o contador.
* Estado vazio **contextual**: "Nenhuma não lida" com o filtro ligado, e não "Nenhuma notificação" —
  senão quem tem a caixa cheia de lidas acha que perdeu tudo.
* O beco da paginação (#54) agora **preserva o filtro** ao resgatar: `?page=5&filtro=nao-lidas`
  vazio volta para `/notificacoes?filtro=nao-lidas`, não para "Todas".

## O bug do contador que só caía no F5

Visto ao vivo depois da primeira entrega: abrir uma notificação a marcava como lida, mas o badge do
sino ficava com o número velho até uma recarga completa.

A causa é uma armadilha de invalidação do SvelteKit, não do domínio. O contador vem do load do
**layout**, que declara `depends('app:unread')` — uma chave que só cai com `invalidate` explícito.
A linha, ao ser aberta, fazia `goto(href)` e mais nada; e navegar de `/notificacoes` para `/agenda`
**não reexecuta o layout**, porque é o mesmo layout. O caminho sem destino nunca teve o problema:
ali o `update()` do enhance já invalida tudo.

Conserto: um `await invalidate('app:unread')` antes do `goto`. O teste que o cobre não checa
markup — ele **captura o callback do `enhance`** (o mock de `$app/forms` guarda o `SubmitFunction`
de cada form) e roda o ciclo do submit, afirmando que o invalidate acontece **antes** da navegação.
Sem isso o bug era invisível à suíte: o mock de enhance era um no-op, e nenhum teste chegava a
executar o que acontece depois do submit.

## Provas

* **Backend:** 1090 testes + 18 doctests, 0 falhas, 91,3 % (gate 80).
* **Web:** 1357 testes, 0 falhas, 91,5 % linhas (gate 80/75); `svelte-check` 0 erros/0 avisos.
* **Gate `:rls`** (role `movimento_app`, NOBYPASSRLS): teste novo — "limpar a caixa alcança as
  linhas sob RLS". Este é o teste que importa. `bulk_destroy` é DELETE em massa com policy
  filter-check (um SELECT de autorização antes), e **sem a GUC ele não erra alto: apaga zero linha e
  devolve sucesso** — a tela diria "limpo" com a caixa intacta. É a mesma classe de bug do
  [doc 35](35-plano-execucao-backlog.md), invisível ao `mix test` (que roda como `postgres`,
  BYPASSRLS).
* **Teto de O(1):** `clear_all` toca a tabela 2 vezes (1 `COUNT` + 1 `DELETE`), asseverado por
  `Api.QueryCounter`. Sem o teto, o caminho volta a ser O(N) sem ninguém perceber — e numa caixa de
  um ano (20.065 linhas, sonda do #54) isso é um travamento.
* **Ao vivo** (Chromium, dev sob `movimento_app`): 23 notificações semeadas → filtro "Não lidas (16)"
  esconde as lidas → "Limpar tudo" → confirmação → caixa vazia, badge do sino **some**, `SELECT
  count(*)` no banco devolve 0. Numa segunda passada, com o filtro já na sidebar: abrir "Abriu vaga
  para a fila" levou a `/fila` **e o badge caiu de 6 para 5 sem F5** (o bug acima), e o ✓ da linha
  marcou lida **sem sair da tela**, derrubando de uma vez os três números — cabeçalho, sidebar e
  sino.

## O `cursor: pointer` que sumiu de TODO botão do app

Achado no acabamento do botão ✓, e não é local: o **Tailwind v4 tirou do preflight** o
`cursor: pointer` que o v3 punha em `button`. Desde a migração (ADR-010), portanto, todo botão do
sistema mostra a seta comum — o que os faz parecer inertes. O projeto tinha só 6 `cursor-pointer`
espalhados, e todos em `<label>`/`<details>`/drop-zone, ou seja, em elementos que precisavam dele
mesmo no v3.

Consertado **uma vez**, na camada base de `app.css`, em vez de espalhar a classe por centenas de
botões:

```css
:where(button, [role='button'], summary):not(:disabled) {
	cursor: pointer;
}
```

`:where` mantém especificidade 0 (qualquer utilitário de cursor continua ganhando) e `:disabled`
fica de fora — botão desabilitado não deve prometer clique. Provado no CSS **compilado e servido**
pelo dev server, não só no fonte.

O botão ✓ em si também era apagado demais (`text-faint`, sem borda): em repouso passava por
enfeite da linha. Agora tem borda e ícone teal, e vira teal sólido no hover.

## Pendências deliberadas

* O `cleared` devolvido é **relato, não promessa**: entre o `COUNT` e o `DELETE` cabe uma
  notificação nova, que sobrevive (e deve mesmo sobreviver).
* Limpar não tem desfazer. Se algum dia isso doer, o caminho é `dismissed_at` (soft-delete), não
  uma lixeira.
