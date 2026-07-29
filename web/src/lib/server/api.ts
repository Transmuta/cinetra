import { env } from '$env/dynamic/private';
import type { RequestEvent } from '@sveltejs/kit';

// Nome do cookie de sessão emitido pela API Phoenix (endpoint.ex :key "_api_key").
export const SESSION_COOKIE = '_api_key';

// Endereço interno da API (server-to-server, pela rede do compose). O browser nunca fala
// direto com a API (ADR-005) — só o BFF, e ele repassa o cookie de sessão.
export function apiBase(): string {
	return env.API_URL ?? 'http://localhost:4000';
}

// Origem PÚBLICA da API (browser-reachable). Usada só para o redirect do OAuth ao provedor,
// que exige uma navegação real do browser — a mesma exceção ao BFF que o WebSocket é.
export function apiPublicOrigin(): string {
	return env.API_PUBLIC_ORIGIN ?? 'http://localhost:4010';
}

// Os headers que TODA chamada do BFF à API carrega, independentemente de haver sessão. São dois,
// por dois motivos distintos:
//
// `x-forwarded-for` — o IP real do cliente, para as chaves de rate limit por IP da API (doc 13,
// causa A). A API é interna, então confia neste header vindo só do BFF; `getClientAddress()` já
// resolve o IP real atrás da edge via ADDRESS_HEADER (web/fly.toml).
//
// As chamadas SEM sessão são justamente as que mais dependem dele: sem ator, a API só tem o IP
// como chave. Sem o header, todo tráfego anônimo do produto (respostas de paciente, callbacks de
// login) colapsa num balde só, o do container do BFF — 200 req/min para o sistema inteiro, e um
// visitante derrubando o login de todos (bate-volta doc 68, causa B). Por isso a função é
// exportada: as duas chamadas sem sessão a usam direto.
//
// `x-request-id` — correlação BFF → API (doc 62 §12). O `Plug.RequestId` do lado Elixir reaproveita
// este header em vez de gerar id próprio, e é assim que a linha da requisição na API, o erro que o
// BFF registrou e o job que ela enfileirou passam a ter a mesma chave.
//
// Os dois são best-effort e **omitidos quando não há valor**, nunca preenchidos com placeholder:
// um `x-forwarded-for` com "undefined" viraria uma chave de rate limit compartilhada por todo
// mundo, e um `x-request-id` fora da faixa 20..200 seria descartado pelo Plug — trocando ausência
// (perceptível) por correlação errada (não perceptível).
export function headersDeContexto(event: RequestEvent, init: HeadersInit = {}): Headers {
	const headers = new Headers(init);
	const clientIp = event.getClientAddress?.();
	if (clientIp) headers.set('x-forwarded-for', clientIp);
	const requestId = event.locals?.requestId;
	if (requestId) headers.set('x-request-id', requestId);
	return headers;
}

// Fetch para a API repassando o cookie de sessão do request atual (BFF).
export function apiFetch(event: RequestEvent, path: string, init: RequestInit = {}): Promise<Response> {
	const headers = headersDeContexto(event, init.headers);
	const session = event.cookies.get(SESSION_COOKIE);
	if (session) headers.set('cookie', `${SESSION_COOKIE}=${session}`);
	return event.fetch(`${apiBase()}${path}`, { ...init, headers });
}

// Re-emite o cookie de sessão da API (`_api_key`) no domínio do WEB, a partir do Set-Cookie
// de uma resposta da API. É o que faz a sessão (e o `state` do OAuth) viverem no web — o
// browser nunca precisa falar direto com a API (ADR-005). Retorna o valor setado, ou null.
// Espelha o token_lifetime do JWT na API (AshAuthentication default = 14 dias). Manter
// alinhado: um cookie que vive mais que o JWT só geraria um "logout súbito" quando o token
// expira mas o cookie ainda existe. `secure` é omitido de propósito — o SvelteKit já ativa
// Secure automaticamente fora de localhost.
const SESSION_MAX_AGE = 60 * 60 * 24 * 14;

export function reemitSession(event: RequestEvent, res: Response): string | null {
	// F1 (doc 34): a API seta `_api_key` (sessão VAZIA) mesmo quando REJEITA o login (401 no
	// callback do magic link / OAuth). Tratar a mera presença do Set-Cookie como sucesso mandava o
	// usuário para `/` parecendo logado, engolindo o `?erro=…`. Só re-emitimos quando a resposta
	// não é um erro — sucesso do callback é um redirect (3xx); a falha é 4xx (com Location de erro).
	if (res.status >= 400) return null;

	const value = extractSessionCookie(res);
	if (value) {
		event.cookies.set(SESSION_COOKIE, value, {
			path: '/',
			httpOnly: true,
			sameSite: 'lax',
			maxAge: SESSION_MAX_AGE
		});
	}
	return value;
}

function extractSessionCookie(res: Response): string | null {
	const list =
		typeof res.headers.getSetCookie === 'function'
			? res.headers.getSetCookie()
			: [res.headers.get('set-cookie') ?? ''];

	for (const cookie of list) {
		const match = cookie.match(new RegExp(`${SESSION_COOKIE}=([^;]+)`));
		if (match) return match[1];
	}
	return null;
}
