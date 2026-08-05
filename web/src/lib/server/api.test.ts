import { describe, it, expect, vi, beforeEach } from 'vitest';

// env dinâmico do SvelteKit: objeto mutável para exercitar fallback e override.
const { mockEnv } = vi.hoisted(() => ({
	mockEnv: {} as Record<string, string | undefined>
}));
vi.mock('$env/dynamic/private', () => ({ env: mockEnv }));

import { apiBase, apiPublicOrigin, apiFetch, reemitSession, SESSION_COOKIE } from './api';

beforeEach(() => {
	for (const k of Object.keys(mockEnv)) delete mockEnv[k];
});

describe('apiBase / apiPublicOrigin', () => {
	it('caem no default quando o env não define', () => {
		expect(apiBase()).toBe('http://localhost:4000');
		expect(apiPublicOrigin()).toBe('http://localhost:4010');
	});

	it('usam o env quando definido', () => {
		mockEnv.API_URL = 'http://api:4000';
		mockEnv.API_PUBLIC_ORIGIN = 'https://api.example.com';
		expect(apiBase()).toBe('http://api:4000');
		expect(apiPublicOrigin()).toBe('https://api.example.com');
	});
});

describe('apiFetch (BFF repassa o cookie de sessão)', () => {
	function fakeEvent(sessionValue?: string, requestId?: string) {
		const fetch = vi.fn().mockResolvedValue(new Response('ok'));
		return {
			fetch,
			getClientAddress: () => '203.0.113.7',
			locals: requestId ? { requestId } : {},
			cookies: { get: (name: string) => (name === SESSION_COOKIE ? sessionValue : undefined) }
		} as never;
	}

	it('anexa o cookie de sessão quando existe', async () => {
		const event = fakeEvent('abc123');
		await apiFetch(event, '/api/auth/me');

		const [url, init] = (event as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch.mock
			.calls[0];
		expect(url).toBe('http://localhost:4000/api/auth/me');
		expect((init.headers as Headers).get('cookie')).toBe(`${SESSION_COOKIE}=abc123`);
	});

	it('NÃO anexa cookie quando não há sessão', async () => {
		const event = fakeEvent(undefined);
		await apiFetch(event, '/api/json/pings');

		const [, init] = (event as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch.mock.calls[0];
		expect((init.headers as Headers).get('cookie')).toBeNull();
	});

	it('honra API_URL do env na URL final', async () => {
		mockEnv.API_URL = 'http://api:4000';
		const event = fakeEvent('x');
		await apiFetch(event, '/api/health');

		const [url] = (event as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch.mock.calls[0];
		expect(url).toBe('http://api:4000/api/health');
	});

	it('repassa o IP do cliente em x-forwarded-for (rate limit por IP da API)', async () => {
		const event = fakeEvent('x');
		await apiFetch(event, '/api/auth/magic-link', { method: 'POST' });

		const [, init] = (event as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch.mock.calls[0];
		expect((init.headers as Headers).get('x-forwarded-for')).toBe('203.0.113.7');
	});

	it('sem getClientAddress não inventa header — mandar lixo é pior que não mandar', async () => {
		// Fora de request handling real o SvelteKit não expõe o endereço. Um `x-forwarded-for`
		// vazio ou "undefined" viraria uma chave de rate limit compartilhada por todo mundo.
		const event = fakeEvent('x') as unknown as Record<string, unknown>;
		delete event.getClientAddress;
		await apiFetch(event as never, '/api/health');

		const [, init] = (event as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch.mock.calls[0];
		expect((init.headers as Headers).has('x-forwarded-for')).toBe(false);
	});

	// R-M19 (onda 5 do doc 102). O `?.` que existia protegia contra a função ser **undefined** —
	// não contra ela **levantar**. E o `getClientAddress()` do adapter-node levanta quando o header
	// configurado em `ADDRESS_HEADER` não vem na requisição, o que vale para QUALQUER header, não
	// só os exóticos: o comentário do `compose.dokploy.yml` afirmava que o `x-forwarded-for` do
	// default "não tem esse risco", e tinha.
	//
	// Quem chega sem passar pelo Traefik: outro serviço na rede `app`, um `curl` de diagnóstico de
	// dentro da `dokploy-network`, um probe futuro. Sem a guarda, cada um virava 500 em toda página
	// que fale com a API.
	it('getClientAddress que LEVANTA não derruba a chamada', async () => {
		const event = fakeEvent('x') as unknown as Record<string, unknown>;
		event.getClientAddress = () => {
			throw new Error('Address header was not set');
		};

		await expect(apiFetch(event as never, '/api/health')).resolves.toBeDefined();

		const [, init] = (event as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch.mock.calls[0];
		expect((init.headers as Headers).has('x-forwarded-for')).toBe(false);
	});

	// R-B9. Com o XFF presente e VAZIO o adapter devolve `''`, e `''` como valor de header é o
	// mesmo estrago do "undefined": todo mundo na mesma chave de rate limit.
	it('endereço vazio é tratado como ausente, não como chave', async () => {
		const event = fakeEvent('x') as unknown as Record<string, unknown>;
		event.getClientAddress = () => '';

		await apiFetch(event as never, '/api/health');

		const [, init] = (event as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch.mock.calls[0];
		expect((init.headers as Headers).has('x-forwarded-for')).toBe(false);
	});

	// Correlação BFF → API. Sem este header, cada navegação gera um `request_id` novo do lado
	// Elixir e não há como ligar o erro que o BFF registrou à requisição que o causou na API.
	it('repassa o request_id do BFF em x-request-id', async () => {
		const event = fakeEvent('x', 'bff-0198cafe-4d2b-71a9-b3e0-5f1c8d7a6e04');
		await apiFetch(event, '/api/agenda');

		const [, init] = (event as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch.mock.calls[0];
		expect((init.headers as Headers).get('x-request-id')).toBe(
			'bff-0198cafe-4d2b-71a9-b3e0-5f1c8d7a6e04'
		);
	});

	it('sem requestId em locals não inventa header', async () => {
		// Mesmo raciocínio do x-forwarded-for acima: um `x-request-id` com "undefined" seria pior
		// que a ausência — o Plug.RequestId o rejeitaria por tamanho e a correlação sairia errada
		// em vez de ausente, que é mais difícil de perceber.
		const event = fakeEvent('x');
		await apiFetch(event, '/api/agenda');

		const [, init] = (event as unknown as { fetch: ReturnType<typeof vi.fn> }).fetch.mock.calls[0];
		expect((init.headers as Headers).has('x-request-id')).toBe(false);
	});
});

describe('reemitSession (re-emite _api_key no domínio do web)', () => {
	function fakeEvent() {
		const set = vi.fn();
		const del = vi.fn();
		return { cookies: { set, del } } as never;
	}

	it('extrai o cookie do Set-Cookie e o re-emite httpOnly/lax', () => {
		const event = fakeEvent();
		const res = new Response('', {
			headers: { 'set-cookie': `${SESSION_COOKIE}=tok.en-value; Path=/; HttpOnly` }
		});

		const value = reemitSession(event, res);

		expect(value).toBe('tok.en-value');
		const set = (event as unknown as { cookies: { set: ReturnType<typeof vi.fn> } }).cookies.set;
		expect(set).toHaveBeenCalledWith(
			SESSION_COOKIE,
			'tok.en-value',
			expect.objectContaining({ path: '/', httpOnly: true, sameSite: 'lax' })
		);
	});

	it('acha o _api_key entre vários Set-Cookie', () => {
		const event = fakeEvent();
		const res = new Response('', {
			headers: [
				['set-cookie', 'outro=1; Path=/'],
				['set-cookie', `${SESSION_COOKIE}=alvo; Path=/`]
			]
		});

		expect(reemitSession(event, res)).toBe('alvo');
	});

	it('sem cookie de sessão: retorna null e não seta nada', () => {
		const event = fakeEvent();
		const res = new Response('', { headers: { 'set-cookie': 'irrelevante=1' } });

		expect(reemitSession(event, res)).toBeNull();
		const set = (event as unknown as { cookies: { set: ReturnType<typeof vi.fn> } }).cookies.set;
		expect(set).not.toHaveBeenCalled();
	});

	// F1 (doc 34): a API emite o cookie _api_key MESMO num 401 (sessão vazia). Tratar "veio
	// Set-Cookie" como sucesso fazia o /auth/callback mandar para / (parecendo logado) em vez de
	// mostrar erro. reemitSession só re-emite quando a resposta NÃO é um erro (status < 400).
	it('resposta de ERRO (401) com _api_key: retorna null e não seta o cookie', () => {
		const event = fakeEvent();
		const res = new Response('', {
			status: 401,
			headers: { 'set-cookie': `${SESSION_COOKIE}=vazio; Path=/; HttpOnly` }
		});

		expect(reemitSession(event, res)).toBeNull();
		const set = (event as unknown as { cookies: { set: ReturnType<typeof vi.fn> } }).cookies.set;
		expect(set).not.toHaveBeenCalled();
	});

	it('redirect de sucesso (302) com _api_key: re-emite normalmente', () => {
		const event = fakeEvent();
		const res = new Response('', {
			status: 302,
			headers: { 'set-cookie': `${SESSION_COOKIE}=tok; Path=/; HttpOnly` }
		});

		expect(reemitSession(event, res)).toBe('tok');
	});
});
