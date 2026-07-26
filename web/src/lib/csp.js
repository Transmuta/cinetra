// Os hosts do `connect-src` da CSP, derivados da origem pública da API (S3, Onda 5).
//
// **Por que é `.js` e não `.ts`:** este módulo é importado pelo `svelte.config.js`, que o Node
// carrega direto, sem passar pelo pipeline do Vite. Um `.ts` ali não compila.
//
// **Por que é build-time:** a `kit.csp` é config do SvelteKit — o header sai do servidor em
// runtime, mas o valor é fixado no build. Por isso a origem entra pelo `ARG`/`ENV` do
// `Dockerfile.prod`, e não pelo `[env]` do fly.toml (que é runtime). Uma imagem construída para
// produção não serve para staging: é o preço de a CSP ser build-time, e está escrito no
// Dockerfile.

/** Origem pública da API em desenvolvimento. Espelha o default de `apiPublicOrigin()` (api.ts). */
export const DEV_API_ORIGIN = 'http://localhost:4010';

/**
 * `http://x` → `ws://x`; `https://x` → `wss://x`, sem barra no fim.
 *
 * **Fonte única da regra de esquema.** Quem monta a URL do socket (`socketUrl`, realtime.ts) e
 * quem a autoriza na CSP (`connectSrc`, aqui) têm de concordar — se divergirem, o browser bloqueia
 * a conexão por um header que ninguém lê até aparecer erro no console. Estavam escritas duas
 * vezes, cada uma com um comentário mandando concordar com a outra: é a duplicação que dói, a que
 * diverge calada.
 *
 * @param {string} origin
 * @returns {string}
 */
export function wsOrigin(origin) {
	return origin.replace(/\/+$/, '').replace(/^http/, 'ws');
}

/**
 * `connect-src` da CSP: `self` mais o par http(s)/ws(s) da API.
 *
 * O WebSocket da agenda é a única conexão do browser que NÃO passa pelo BFF (ADR-004/005), então
 * `self` não basta. A regra de esquema é a mesma de `socketUrl` (realtime.ts) — quem monta a URL
 * do socket e quem a autoriza têm de concordar. `ws:`/`wss:` genéricos liberariam qualquer
 * destino, que é o que a CSP existe para impedir.
 *
 * @param {string | undefined} apiPublicOrigin
 * @returns {string[]}
 */
export function connectSrc(apiPublicOrigin) {
	const origin = (apiPublicOrigin || DEV_API_ORIGIN).replace(/\/+$/, '');
	return ['self', origin, wsOrigin(origin)];
}

/**
 * A origem que o runtime vai discar está entre as que a CSP **assada** autoriza?
 *
 * Existe porque as duas pontas leem a mesma variável em momentos diferentes: a `kit.csp` fixa o
 * `connect-src` no **build** (por isso `[build.args]` no fly.toml), e o BFF resolve
 * `API_PUBLIC_ORIGIN` em **runtime** (por isso `[env]`). Divergir não dá erro de servidor: dá
 * agenda que para de atualizar sozinha, com o motivo só no console do browser do usuário. É o
 * tipo de falha que um deploy passa verde.
 *
 * Devolve `null` quando está tudo certo, ou a mensagem a levantar. Não levanta aqui: quem decide
 * o que fazer com o problema é o `hooks.server.ts` — assim esta parte continua testável sem
 * derrubar processo.
 *
 * Dev e CI não disparam por omissão: sem configuração, os dois lados caem no mesmo
 * `DEV_API_ORIGIN`. Só divergência de verdade acende.
 *
 * @param {string[]} autorizadas  o `connect-src` que foi assado no build
 * @param {string} origemRuntime  o `API_PUBLIC_ORIGIN` que o servidor está lendo agora
 * @returns {string | null}
 */
export function conferirOrigem(autorizadas, origemRuntime) {
	const origem = (origemRuntime || DEV_API_ORIGIN).replace(/\/+$/, '');

	if (autorizadas.includes(origem)) return null;

	return (
		`A CSP assada no build não autoriza a origem que o runtime vai usar para o WebSocket.\n` +
		`  runtime (API_PUBLIC_ORIGIN):  ${origem}\n` +
		`  connect-src assado no build: ${autorizadas.join(' ')}\n` +
		`Iguale API_PUBLIC_ORIGIN em [build.args] e [env] no web/fly.toml (ver docs/17).`
	);
}
