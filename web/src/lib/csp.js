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
	return ['self', origin, origin.replace(/^http/, 'ws')];
}
