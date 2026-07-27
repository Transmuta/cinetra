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
 * A origem do bucket de anexos (Cloudflare R2, doc 51), derivada do id da conta.
 *
 * Derivada, e não uma variável própria, porque o `R2_ACCOUNT_ID` já precisa existir para a API
 * assinar as URLs: duas variáveis para o mesmo endereço são duas chances de divergirem, e a
 * divergência aqui só aparece no console do browser de quem tenta subir um laudo.
 *
 * @param {string | undefined} accountId
 * @returns {string | null}
 */
export function r2Origin(accountId) {
	const id = (accountId || '').trim();
	return id ? `https://${id}.r2.cloudflarestorage.com` : null;
}

/**
 * `connect-src` da CSP: `self`, o par http(s)/ws(s) da API e — quando configurado — o bucket.
 *
 * Duas conexões do browser NÃO passam pelo BFF (ADR-004/005), e por isso `self` não basta:
 *
 *   1. o **WebSocket** da agenda, que vai direto ao Phoenix. A regra de esquema é a mesma de
 *      `socketUrl` (realtime.ts) — quem monta a URL do socket e quem a autoriza têm de concordar;
 *   2. o **`PUT` do anexo**, que vai direto ao R2 por URL assinada. É `fetch`, logo cai em
 *      `connect-src`; sem esta entrada o upload morre com o motivo só no console (doc 51 §5.3).
 *
 * O bucket entra apenas se houver `R2_ACCOUNT_ID` no build — sem ele a fatia de anexos já está
 * desligada na API (503), e não há por que abrir um destino a mais na política.
 *
 * `ws:`/`wss:` genéricos, ou `https://*.r2.cloudflarestorage.com`, liberariam qualquer destino —
 * inclusive o bucket de outra conta. É exatamente o que a CSP existe para impedir.
 *
 * @param {string | undefined} apiPublicOrigin
 * @param {string} [r2AccountId]  omitido/vazio = sem bucket no `connect-src`
 * @returns {string[]}
 */
export function connectSrc(apiPublicOrigin, r2AccountId) {
	const origin = (apiPublicOrigin || DEV_API_ORIGIN).replace(/\/+$/, '');
	const bucket = r2Origin(r2AccountId);

	return ['self', origin, wsOrigin(origin), ...(bucket ? [bucket] : [])];
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
