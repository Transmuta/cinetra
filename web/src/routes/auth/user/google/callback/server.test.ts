import { describe, it, expect, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({ env: {} }));

import { GET } from './+server';
import { SESSION_COOKIE } from '$lib/server/api';
import { VERSAO } from '$lib/legal';

async function caught(fn: () => Promise<unknown>) {
	try {
		await fn();
		throw new Error('esperava um redirect');
	} catch (e) {
		return e as { status: number; location: string };
	}
}

function fakeEvent(setCookie?: string) {
	const url = new URL('http://web/auth/user/google/callback?code=xyz&state=abc');
	const headers: Record<string, string> = setCookie ? { 'set-cookie': setCookie } : {};
	const fetch = vi.fn().mockResolvedValue(new Response('', { headers }));
	const set = vi.fn();
	return { event: { url, fetch, cookies: { get: () => 'state-cookie', set } } as never, fetch, set };
}

describe('GET /auth/user/google/callback (Google devolve code+state no BFF)', () => {
	it('sessão assinada pela API: re-emite o cookie e vai para /', async () => {
		const { event, fetch, set } = fakeEvent(`${SESSION_COOKIE}=assinado; Path=/`);
		const r = await caught(() => GET(event));

		// repassa o code+state (query string) à API.
		expect(fetch.mock.calls[0][0]).toContain('/api/auth/strategy/user/google/callback?code=xyz');
		expect(set).toHaveBeenCalledWith(SESSION_COOKIE, 'assinado', expect.any(Object));
		expect(r.status).toBe(303);
		expect(r.location).toBe('/');
	});

	it('API não assina sessão: volta a /entrar?erro=google', async () => {
		const { event, set } = fakeEvent(); // sem Set-Cookie
		const r = await caught(() => GET(event));

		expect(set).not.toHaveBeenCalled();
		expect(r.location).toBe('/entrar?erro=google');
	});
});

// `[D-14]` / doc 101 A4. Este é o caminho que uma caixa de seleção no `/criar-conta` NÃO
// alcançaria: o botão do Google é um `<a>` de navegação completa (doc 76 §1).
describe('o aceite dos documentos legais', () => {
	it('registra a versão exibida depois de a sessão ser assinada', async () => {
		const { event, fetch } = fakeEvent(`${SESSION_COOKIE}=assinado; Path=/`);
		await caught(() => GET(event));

		const aceite = fetch.mock.calls.find((c) => String(c[0]).includes('/api/auth/terms-acceptance'));

		expect(aceite).toBeTruthy();
		expect(JSON.parse(aceite![1].body)).toEqual({ versao: VERSAO });
	});

	it('sem sessão assinada, não registra nada', async () => {
		const { event, fetch } = fakeEvent();
		await caught(() => GET(event));

		expect(
			fetch.mock.calls.some((c) => String(c[0]).includes('terms-acceptance'))
		).toBe(false);
	});
});
