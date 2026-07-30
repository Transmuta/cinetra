# E2E — como rodar, e para onde apontar

Estes testes **não rodam no CI** (decisão de 2026-07-27). Eles precisam da stack inteira — API,
banco e, nos cenários autenticados, a caixa de e-mail de dev de onde sai o magic link —, e o
workflow do CI sobe só o `web`. Um job que pula com aviso é ruído com cara de cobertura.

## Local (o caso normal)

Com o `docker compose up` de pé:

```bash
docker compose exec web npx playwright install --with-deps chromium   # 1ª vez
docker compose exec web npm run test:e2e
```

O Playwright faz `build` + `preview` sozinho na porta 4173 e fala com a API pela rede do compose
(`API_URL=http://api:4000`).

## Apontando para outro ambiente (hml, produção)

Duas variáveis, nada mais:

```bash
E2E_BASE_URL=https://hml.exemplo.com \
E2E_API_ORIGIN=https://api-hml.exemplo.com \
  npm run test:e2e
```

Com `E2E_BASE_URL` definido, o `webServer` **não sobe** — o alvo já está no ar.

| Variável | O que é | Default |
| --- | --- | --- |
| `E2E_BASE_URL` | O **web** (é a `baseURL` do Playwright) | `http://localhost:4173`, com build+preview automáticos |
| `E2E_API_ORIGIN` | A **API**, a partir do processo do Playwright | `API_URL` → `API_PUBLIC_ORIGIN` → `http://localhost:4010` |

> **Cuidado com a origem da API.** `API_PUBLIC_ORIGIN` é a origem *pelo browser do host*
> (`localhost:4010`); rodando dentro do container, a que resolve é `API_URL` (`http://api:4000`).
> Trocar as duas fez a primeira execução **pular em silêncio** achando que a stack estava fora do
> ar — que é pior que falhar.
>
> Essa origem passou a ser resolvida num lugar só ([`env.ts`](env.ts)), e o `playwright.config.ts`
> a repassa ao `webServer` como `API_PUBLIC_ORIGIN` — para o **build** (a CSP é assada nele) e para
> o **runtime**. Sem esse repasse, o browser dentro do container herdava `localhost:4010` (o
> endereço de quem navega do host) e o WebSocket morria em silêncio, com o motivo só no console.

## O andaime: a fixture `clinica`

[`fixtures.ts`](fixtures.ts) dá a cada teste uma clínica própria: dono autenticado por um magic
link **de verdade** (é esse encanamento que o e2e existe para provar) e o cenário — profissional,
paciente, tipo — semeado por HTTP, porque nenhum destes testes está verificando o formulário de
cadastro. Uma clínica por teste é também o que deixa a suíte rodar em paralelo: o tenant é o limite
de isolamento do sistema (ADR-017), então dois testes nunca disputam a mesma agenda.

```ts
import { test, expect, abrirAgenda, blocos } from './fixtures';

test('…', async ({ page, clinica }) => {
	await abrirAgenda(page, clinica); // já hidratada — ver abaixo
	await expect(blocos(page)).toHaveCount(0);
});
```

Dois cuidados que já custaram uma depuração cada:

- **Hidratação.** A grade vem no HTML do SSR, então um `expect(...).toBeVisible()` passa na hora — e
  clicar ali ainda atinge um DOM **sem handler**: o clique some sem erro nenhum, e a falha aparece
  cinco segundos depois apontando para o modal que não abriu. `abrirAgenda` espera o pedido do token
  do WebSocket, que sai de um `$effect` e só existe no cliente.
- **Join do canal.** Entre abrir o socket e o `phx_reply` do join há um round-trip, e evento emitido
  nessa janela não chega a ninguém. `joinDaAgenda`/`joinDoCanal` esperam o join de fato — é o que
  separa "testa tempo real" de "teve sorte".

## O que roda em cada ambiente

| Spec | Precisa de | Contra hml/prod? |
| --- | --- | --- |
| `login.spec.ts`, `theme.spec.ts` (parte) | só o web | sim |
| todos os demais | API + banco + **caixa de dev** (`/dev/mailbox`) | **não** — sem `dev_routes` não há como ler o magic link |

Os cenários autenticados pulam sozinhos quando a caixa de dev não responde (`stackCompleta/1` em
`helpers.ts`). Em ambiente sem mailbox, autenticar exige outro caminho — é o que falta decidir para
esta suíte apontar para hml.

## Quando um destes ficar vermelho

Cada spec tem, no topo, **a classe de bug que ele guarda** — quase todas com histórico neste
repositório. Vermelho aqui raramente é "o teste está frágil": leia o cabeçalho antes de mexer no
seletor. O mapa completo, spec a spec, está em [`docs/16`](../../docs/16-testes-frontend.md).

O relatório fica em `playwright-report/`; a falha guarda ainda um `error-context.md` com o snapshot
de acessibilidade da tela no instante do erro, que costuma responder sozinho por que um seletor não
casou.
