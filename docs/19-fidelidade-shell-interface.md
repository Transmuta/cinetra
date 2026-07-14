# 19 — Fidelidade do shell ao protótipo (`interface/`)

Comparativo entre o protótipo de referência (`interface/Movimento.dc.html` + `interface/screenshots/`)
e o shell administrativo do `web/`, e o que foi ajustado para ficar fiel. Foco: **chrome** do app
(rail, topbar, sidebar) e o **menu do usuário**. Nada de backend novo — a infraestrutura já existia.

> **Refinamentos da 2ª rodada** (ver seção no fim): o **avatar do usuário foi para o topbar** (canto
> superior direito) e o **toggle de tema desceu para o rodapé do rail** — uma inversão **pedida pelo
> usuário**, que diverge de propósito do protótipo. Foi adicionada a **experiência mobile** (hambúrguer
> + gaveta) e a **tabela de membros** ficou robusta. As tabelas abaixo descrevem o estado final.

## Comparativo

### Rail (coluna escura à esquerda)

| Aspecto | Protótipo | Antes | Depois |
| --- | --- | --- | --- |
| Marca (topo) | Ícone `Activity` (pulso) branco sobre teal, com brilho | Letra **"M"** | `Activity` ✅ |
| Rodapé | spacer → **sino** → **avatar do usuário** | spacer → **botão Sair** | spacer → **sino** → **toggle de tema** (rail) |

> Estado final: o avatar saiu do rail (foi para o topbar, por pedido do usuário) e o **toggle de tema**
> ocupou o rodapé — na variante escura do rail, ao lado do sino.

### Topbar (header)

| Aspecto | Protótipo | Antes | Depois |
| --- | --- | --- | --- |
| Faixa teal de 2px no topo | Sim | Não | Sim ✅ |
| Esquerda | Título da seção (+ hambúrguer no mobile) | Título | **Hambúrguer (mobile)** + título |
| **Direita** | Toggle de tema (Sol/Lua) | badge da clínica + toggle + avatar com nome/e-mail | **Avatar do usuário → menu** |

> **Divergência intencional do protótipo** (pedido do usuário): trocamos as posições do toggle de tema
> e do avatar. O avatar (menu do usuário) fica no canto superior direito; o toggle desceu para o rail.

### Sidebar (coluna clara)

Já era fiel: "Movimento" + nome da clínica com pino de mapa. O nome da clínica que **saiu do topbar não
se perde** — continua aqui.

### Menu do usuário (novo)

Clicar no avatar (rodapé do rail) abre um popover com, nesta ordem:

1. **Identidade** — nome + e-mail.
2. **Meu perfil** — link para `/perfil` (stub por ora; a tela vem numa fatia futura, seguindo a
   convenção de andaime dos demais destinos).
3. **Clínicas** — uma linha por vínculo (`me.memberships`), com papel; a ativa aparece marcada e
   desabilitada, as demais **trocam o tenant** ao clicar.
4. **Nova clínica** — leva ao onboarding no fluxo de clínica adicional (`/comecar?nova=1`).
5. **Sair** — logout.

## Infra que já existia (nenhum backend novo)

- `me.memberships` (clínicas + papel) e `me.active_clinic_id` já vinham no `/api/auth/me`.
- Troca de tenant: `POST /api/auth/switch-tenant {clinic_id}` já existia na API (valida o vínculo,
  reemite a sessão). Criar clínica adicional: a ação `:onboard` aceita **qualquer autenticado**
  (`actor_present()`) — quem via o onboarding era decisão do BFF, não da API.
- Logout: `POST /api/auth/sign-out` já existia.

## O que mudou no `web/`

**BFF / servidor**

- `lib/server/clinics.ts` — `onboardClinic` passa a devolver o `clinicId` criado; novo `switchTenant`
  (POST para a API + `reemitSession`, o mesmo padrão do callback de login).
- `routes/auth/switch-clinic/+server.ts` — **nova** rota `POST` (proteção CSRF, como o sign-out):
  troca o tenant ativo e volta para a home.
- `routes/comecar/+page.server.ts` — guard relaxado para `?nova=1` (dono existente cria outra
  clínica); ao criar no fluxo "nova", troca o tenant ativo para a recém-criada antes de ir à home.
- `routes/comecar/+page.svelte` — variante de texto + link "Voltar" quando `nova`.

**Shell (componentes)**

- `lib/components/shell/UserMenu.svelte` — **novo**: avatar + popover (perfil, clínicas, nova, sair);
  fecha por clique-fora e `Esc`.
- `lib/components/shell/Rail.svelte` — marca `Activity`, remove o botão Sair, adiciona sino +
  `UserMenu`; passa a receber `me`.
- `lib/components/shell/Topbar.svelte` — enxuto para título + toggle de tema + faixa teal; deixa de
  receber `me`/`clinicName`.
- `routes/(app)/+layout.svelte` — passa `me` ao `Rail`; para de passar `me`/`clinicName` ao `Topbar`.

Testes acompanham cada mudança (TDD; ver `.claude/rules/testes.md`): `clinics.test.ts`,
`auth/switch-clinic/server.test.ts`, `comecar/page.server.test.ts`, `UserMenu.svelte.test.ts`,
`Rail.svelte.test.ts`, `Topbar.svelte.test.ts`.

## Refinamentos (2ª rodada de review)

1. **Inverter toggle de tema ↔ avatar** (pedido do usuário). O avatar (menu do usuário) foi para o
   canto superior direito do topbar; o toggle de tema desceu para o rodapé do rail.
   - `ThemeToggle.svelte` ganhou `variant: 'default' | 'rail'` (estilo escuro do rail).
   - `UserMenu.svelte` ganhou `placement: 'topbar' | 'rail'` (o popover abre para baixo/direita no
     topbar, ou para cima/direita no rail).
   - `Rail.svelte` volta a NÃO receber `me` (só `theme`); `Topbar.svelte` volta a receber `me` (e um
     `onMenu` para o hambúrguer). O sino continua no rail.

2. **Experiência mobile** (antes inexistente). Abaixo de `lg` (1024px) o rail + sidebar viram uma
   **gaveta** aberta por um **hambúrguer** no topbar; um backdrop e `Esc` fecham, e navegar fecha
   sozinho (`afterNavigate`). Acima de `lg`, rail + sidebar ficam fixos.
   - `routes/(app)/+layout.svelte` — estado `drawerOpen`, wrapper `hidden lg:flex` (desktop) + gaveta
     `lg:hidden`.
   - `Sidebar.svelte` — deixa de esconder a si mesmo (`hidden md:flex` → `flex`); a visibilidade agora é
     do layout. Breakpoint `lg` (não `md`): abaixo dele o conteúdo ocupa a largura toda, então a tabela
     de membros não fica espremida pelos 312px de cromo.

3. **Tabela de membros robusta** (`configuracoes/equipe/+page.svelte`):
   - Header **empilha** no mobile (título/descrição numa linha, botão "Convidar membro" full-width
     embaixo) e volta lado a lado em `sm+`.
   - Linhas: grade só em `md+` com colunas `minmax(0, …)` + `min-w-0` (o `truncate` do nome/e-mail passa
     a funcionar, some o estouro). No mobile viram **card empilhado** (identidade + ações no topo, papel
     + status, e o vínculo só quando há) — espelhando o `cfgEquipe(narrow)` do protótipo.
   - Ações da linha extraídas para um `{#snippet}` (DRY entre mobile e desktop).
   - **Alinhamento das colunas** (bug do "cada linha quebrando no desktop"): cabeçalho e cada linha são
     **grids independentes**; com a coluna de ações em `auto`, o cabeçalho (0 botões) e as linhas (2 ou 3
     botões, conforme pendente) resolviam os `fr` sobre larguras diferentes → colunas desalinhadas. Fixei
     a coluna de ações em **`112px`** (cabeçalho e linhas) e igualei o padding horizontal (`px-1` nos
     dois), então todas as trilhas resolvem idêntico e as colunas encaixam.
   - **Coluna "Papel"** (era "Papel e status"): o status "Ativo" é o padrão e ficou **implícito** (deixou
     de aparecer). O convite **pendente** continua sinalizado ("Convite pendente"), pois não é "ativo" e
     indica quem ainda não entrou.

## Pendências conscientes

- **Badge de contagem na Fila** (o protótipo mostra um número): adiado — não há fonte de dados de fila
  nesta fatia.
- **Sino de notificações**: placeholder visual; sem feature ainda (clique inerte). Continua no rail
  (não foi movido junto com o avatar).
- **`/perfil`**: stub (404) até a fatia da tela de perfil.
- **Verificação mobile**: as classes responsivas (`lg:hidden`/`hidden lg:flex`) e a gaveta foram
  conferidas por `svelte-check` + testes; a captura visual em viewport estreito ficou bloqueada pelo
  MCP do Playwright desta sessão (viewport fixo, sem `evaluate`/resize).
