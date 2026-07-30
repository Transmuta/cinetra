# Testes do frontend (a pirâmide no BFF/SvelteKit)

Par frontend do [15-gate-de-cobertura-e-ci.md](15-gate-de-cobertura-e-ci.md) e aplicação da
mesma filosofia do [07-estrategia-de-testes.md](07-estrategia-de-testes.md) §7 ao `web/`:
**base larga de unitário, integração no meio, e2e só nos cenários críticos.** A regra de
ouro é a mesma — cada comportamento é provado no nível mais baixo em que ele pode existir;
o e2e cobre o encanamento, não as regras.

O `web/` é um **BFF** (ADR-005): o browser nunca fala com a API; o SvelteKit repassa tudo
server-to-server, re-emitindo o cookie de sessão. Então o "motor" a testar aqui é a lógica
de servidor do BFF — repasse de cookie, re-emissão de sessão, resposta neutra — não a UI.

## Ferramentas

- **Vitest 4** com dois *projects* (config em [`web/vite.config.ts`](../web/vite.config.ts)):
  - `client` (jsdom): componentes Svelte 5 — arquivos `*.svelte.test.ts`, via
    `@testing-library/svelte`.
  - `server` (node): lógica de BFF e route handlers — `*.test.ts` em `src/lib/server` e
    `src/routes`.
- **Playwright** ([`web/playwright.config.ts`](../web/playwright.config.ts)): sobe o app
  buildado (`build` + `preview`) e dirige o Chromium. Só cenários críticos.
- Scripts: `npm run test:unit` (Vitest), `npm run test:e2e` (Playwright), `npm test` (ambos).

## O que é testado, por nível

### Unitário (o motor do BFF) — `src/lib/server`, `src/hooks.server.ts`

- **`api.ts`** — o coração de segurança do BFF: `apiFetch` **anexa** o cookie de sessão
  quando existe e **não anexa** quando não existe; `reemitSession` extrai o `_api_key` do
  `Set-Cookie` (inclusive entre vários) e o re-emite `httpOnly`/`lax`, ou retorna `null`;
  `apiBase`/`apiPublicOrigin` caem no default ou honram o env.
- **`auth.ts`** — `requestMagicLink`: e-mail vazio → `fail(400)` sem chamar a API; válido →
  `POST /api/auth/magic-link` e `{sent:true}`; **falha de rede não vaza** (ainda `{sent:true}`,
  resposta neutra do ADR-015); faz `trim`.
- **`hooks.server.ts`** — `handle`: cookie `mv-theme` dark/light estampa `data-theme`;
  ausente/ inválido não estampa (deixa o `prefers-color-scheme` decidir); `lang` = pt-BR.

### Integração — route handlers + componentes

- **Route handlers** (compõem `apiFetch` + `redirect` + cookies):
  - `auth/callback` (magic link): sem token → `/entrar?erro=link`; sessão emitida →
    re-emite e vai para `/`; sessão não emitida → volta com erro.
  - `auth/sign-out`: `DELETE` na API, apaga o cookie local, redireciona — **mesmo se a API
    falhar**, o cookie some.
  - `+page.server` (`load`): agrega `/me` + `/pings`; 401 no `/me` → `me` null sem quebrar;
    200 sem `user` → `me` null (não confia em corpo vazio); erro nos pings → mensagem.
- **Componentes** (`@testing-library/svelte`) — **os 7**: `Button` (button vs link por `href`,
  disabled), `Field` (label↔input, name/type/required/value), `ThemeToggle` (alterna aria-label,
  estampa `data-theme` e persiste o cookie), `AuthCard` (título/subtítulo/conteúdo/rodapé +
  toggle), `AuthForm` (estado neutro vs formulário vs erro — com `$app/forms`/`$app/state`
  mockados), `Logo` e `GoogleIcon`.

### Tripwires de design system — o teste que lê a fonte

Duas exceções ao "teste exercita código": estes **leem a definição** e a medem. Existem porque a
paleta passou por duas rodadas de calibragem visual com pares em 2,03:1 sem nada acusar
([doc 83](83-acessibilidade-analise-completa.md), [ADR-019](00-decisoes.md#adr-019--cor-semântica-é-dois-tokens-fundo-fixo-e-texto-por-tema)):

- [`styles/contraste.test.ts`](../web/src/lib/styles/contraste.test.ts) — abre o `app.css`, extrai
  os tokens dos dois temas e mede: texto nas 3 superfícies **e** na tinta de 14% da própria cor,
  fundo sólido + `on-solid`, e o anel de foco em toda superfície (inclusive o rail escuro). Lê o CSS
  em vez de repetir os hex de propósito — um teste com os valores à mão concorda com o CSS até o dia
  em que divergem. Também confere a **regra** `:focus-visible`, porque a primeira versão media só os
  tokens e passava verde com o anel invisível no tema claro.
- [`contraste.test.ts`](../web/src/lib/contraste.test.ts) — as paletas categóricas (avatar, tipo,
  prioridade), que vêm de lista e são contrato com o servidor: para toda cor, `textoSobre()` tem de
  alcançar 4,5. Cor nova que não sirva a nenhum dos dois textos reprova aqui, que é o momento certo.

### E2E (Playwright) — só o crítico

O critério de entrada **não é cobrir rota**: é cobrir uma **classe de bug que só o browser
contra a stack de verdade pega**. Com ~1.500 testes de unidade e ~820 no backend, e2e que
reafirma regra é custo puro. As classes que sobram, e o cenário que guarda cada uma:

| Spec | A classe de bug que só ele pega |
| --- | --- |
| [`login`](../web/e2e/login.spec.ts) | O estado **neutro** do ADR-015 na tela (e o split da auth que some no mobile — regra de media query, que nem o jsdom aplica). |
| [`theme`](../web/e2e/theme.spec.ts) | Tema sem flash: cookie do cliente → `hooks.server` re-estampa no SSR. Só a volta inteira prova. |
| [`switch-clinic`](../web/e2e/switch-clinic.spec.ts) | Troca de tenant: cookie + `Membership` + `Api.Scope` + GUC de RLS concordando **na tela seguinte**. |
| [`agendar`](../web/e2e/agendar.spec.ts) | O caminho mais rico de RLS (leitura + escrita por tenant), e a conversão de fuso do modal — invisível numa máquina que roda em UTC, que é o container. |
| [`tempo-real`](../web/e2e/tempo-real.spec.ts) | WebSocket de verdade: token no subprotocolo, `check_origin` e **CSP** (que é assada no build e só existe em app buildado). O `realtime.test.ts` faz `vi.mock('phoenix')` — a camada do fio ali é dublê. |
| [`notificacoes`](../web/e2e/notificacoes.spec.ts) | O badge que cai **sem F5**: `goto` não reexecuta load de layout, e o mock no-op de `enhance` esconde isso da unidade. Regressão de bug visto ao vivo. |
| [`excluir-agendamento`](../web/e2e/excluir-agendamento.spec.ts) | `requestSubmit()` a partir de um ConfirmDialog — sem `await tick()` o Svelte 5 manda o form **vazio**, e o `fireEvent` da unidade não pega. Sete telas usam esse molde. |
| [`isolamento`](../web/e2e/isolamento.spec.ts) | Vazamento entre clínicas pelo caminho HTTP inteiro, com o role `cinetra_app` (NOBYPASSRLS) — o `mix test` conecta como superusuário e é cego a isso. |
| [`recepcao`](../web/e2e/recepcao.spec.ts) | RBAC afirmado em três lugares (policy, controller, gating de UX) **concordando**, com contraste owner × recepção na mesma tela. |
| [`console`](../web/e2e/console.spec.ts) | Varredura do shell: erro de console/CSP em qualquer tela, e `<a>` para endpoint `+server` sem `data-sveltekit-reload` (404 no roteador de cliente). |
| [`a11y-audit`](../web/e2e/a11y-audit.spec.ts) · [`a11y-interno`](../web/e2e/a11y-interno.spec.ts) | **Gate de acessibilidade** (axe-core, WCAG 2.0/2.1 A+AA): 5 páginas públicas e 21 telas/estados internos, diálogos e mobile inclusos. Contraste e regra de ARIA só existem **pintados**, e a `a11y-interno` mede com dado semeado porque tela vazia não tem linha para reprovar. Ver [doc 83](83-acessibilidade-analise-completa.md) §9. |
| [`a11y-teclado`](../web/e2e/a11y-teclado.spec.ts) · [`a11y-anexos`](../web/e2e/a11y-anexos.spec.ts) | **Sondas** (relatam, não barram): quantos Tabs até o conteúdo, se o foco escapa do diálogo, reflow a 320/640px, e se o input de arquivo está na ordem de tabulação. É o que o axe não vê — e o que uma regressão dessas quebra primeiro é o teste de unidade do componente. |

**O andaime** ([`e2e/fixtures.ts`](../web/e2e/fixtures.ts)): a fixture `clinica` dá a cada teste
uma clínica própria — dono autenticado por magic link **de verdade**, e o cenário (profissional,
paciente, tipo) semeado por HTTP. Semear pela interface custava seis telas por arquivo e fazia a
falha de qualquer uma delas quebrar todos os testes no lugar errado. Uma clínica por teste é
também o que deixa a suíte rodar em paralelo: o tenant é o limite de isolamento do sistema.

## Gate de cobertura (Vitest v8)

Análogo ao `minimum_coverage` do backend. Configurado em
[`web/vite.config.ts`](../web/vite.config.ts) (`test.coverage`), rodado por `npm run coverage`
(= `vitest run --coverage`), **falha abaixo do threshold**.

- **Escopo** (`include`): `src/lib/**` (server + componentes), `src/hooks.server.ts` e os
  route handlers `src/routes/**/*.ts`. As **páginas `.svelte`** (SSR) ficam fora — são
  território de e2e, como o backend deixa `endpoint`/`telemetry` fora. `assets`/`styles` e os
  `*.test.ts` também são excluídos.
- **Thresholds**: 80% em lines/statements/functions (alinhado ao gate do backend); **branches
  em 75%** de propósito — o v8 conta fallbacks defensivos que não rodam no ambiente de teste
  (`matchMedia`, `getSetCookie`), inerentemente abaixo.
- **Atual**: statements **96,98%**, lines **95,65%**, functions **97,72%**, branches **82,19%**.

## Estado

**1.538 testes Vitest (151 arquivos) + 12 Playwright, todos verdes.** `svelte-check` limpo.

## CI ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml))

- Job **web**: `npm run check` (svelte-check) → `npm run coverage` (testes + gate) → `npm run build`.
- **O e2e não roda no CI** (decisão de 2026-07-27): ele precisa da stack inteira — API, banco e a
  caixa de e-mail de dev de onde sai o magic link —, e o workflow sobe só o `web`. Roda local,
  contra o `docker compose`; a receita está em [`web/e2e/README.md`](../web/e2e/README.md).

## O que ainda falta (ratchet)

- **Cobertura do backend com número por-dimensão**: o Elixir usa um piso único (linha) de 80%;
  aqui temos branch/function/statement separados. Simetria opcional.
- **`e2e/` fica fora do `svelte-check`**: o `include` do tsconfig gerado cobre `src/`, `test/` e
  `tests/` — não `e2e/`. O Playwright transpila com esbuild, que **apaga** os tipos sem conferi-los,
  então um erro de tipo ali só aparece (se aparecer) em tempo de execução. Ampliar o `include` é
  reescrever a lista herdada inteira; fica anotado como dívida consciente.
- Jornadas ainda sem e2e, por ordem de valor: **arrastar** um bloco para remarcar (o gesto tem
  limiar, captura de ponteiro e supressão de clique — nada disso existe fora do browser), **oferecer
  vaga da fila** e o **upload de anexo** (o `PUT` sai do browser direto para o R2, então preflight
  de CORS e `connect-src` do bucket só existem ali; precisa de credencial, então entraria com skip
  quando o R2 não estiver configurado).
