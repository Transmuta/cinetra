/**
 * A origem da API — resolvida **uma vez**, porque três consumidores precisam concordar sobre ela:
 *
 *   1. o processo do Playwright, que fala com a API para semear e para ler a caixa de dev;
 *   2. o **browser**, que disca o WebSocket direto no Phoenix (a exceção ao ADR-005);
 *   3. o **build** do app, que assa essa mesma origem no `connect-src` da CSP (build-time — ver
 *      `src/lib/csp.js`), e cujo servidor confere no boot se ela bate com a de runtime.
 *
 * Os três rodam na MESMA máquina (o container do compose, ou o host), então uma origem só serve
 * aos três — e é por isso que `playwright.config.ts` a repassa como `API_PUBLIC_ORIGIN` para o
 * `webServer`. Sem esse repasse, o browser dentro do container herdava `http://localhost:4010` (a
 * origem de quem navega **do host**) e o socket nunca conectava: agenda estática, erro só no
 * console, e o teste de tempo real falhando por ambiente em vez de por regressão.
 *
 * A ordem importa: dentro do container `API_URL` (a rede interna do compose) é a que resolve, e a
 * pública **não**. No host acontece o contrário, e nenhuma das duas está definida — daí o default.
 */
export const API_ORIGIN =
	process.env.E2E_API_ORIGIN ??
	process.env.API_URL ??
	process.env.API_PUBLIC_ORIGIN ??
	'http://localhost:4010';
