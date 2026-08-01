import { describe, it, expect, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({ env: {} }));

import { load } from './+page.server';
import { SESSION_COOKIE } from '$lib/server/api';

function json(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

// Roteia o fetch do BFF por fragmento de path (só /api/auth/me neste load). `logado` decide se
// o evento carrega o cookie de sessão — sem ele o `loadMe` nem chega à API (doc 57).
function fakeEvent(routes: Record<string, Response>, logado = true, href = 'https://cinetra.app/') {
	const fetch = vi.fn((url: string) => {
		for (const [frag, res] of Object.entries(routes)) {
			if (url.includes(frag)) return Promise.resolve(res);
		}
		return Promise.resolve(new Response('', { status: 404 }));
	});
	return {
		fetch,
		url: new URL(href),
		cookies: { get: (n: string) => (logado && n === SESSION_COOKIE ? 'tok' : undefined) }
	} as never;
}

// A raiz é a landing pública: deslogado renderiza; logado é mandado para onde pertence.
describe('load / (landing pública)', () => {
	it('visitante anônimo → renderiza a landing com a canônica da página', async () => {
		const event = fakeEvent({}, false);
		await expect(load(event)).resolves.toEqual({
			canonical: 'https://cinetra.app/',
			origem: 'https://cinetra.app'
		});
	});

	it('a canônica descarta a query (campanha não cria URL canônica nova)', async () => {
		const event = fakeEvent({}, false, 'https://cinetra.app/?utm_source=instagram');
		await expect(load(event)).resolves.toMatchObject({ canonical: 'https://cinetra.app/' });
	});

	it('sessão inválida (401 no /me) → renderiza a landing', async () => {
		const event = fakeEvent({ '/api/auth/me': json({ error: 'unauthenticated' }, 401) });
		await expect(load(event)).resolves.toMatchObject({ canonical: 'https://cinetra.app/' });
	});

	it('logado sem clínica → 307 para /comecar', async () => {
		const event = fakeEvent({
			'/api/auth/me': json({ user: { id: 'u1', nome: 'Ana' }, active_clinic_id: null })
		});
		await expect(load(event)).rejects.toMatchObject({ status: 307, location: '/comecar' });
	});

	it('logado com clínica → 307 para a home do app (shell)', async () => {
		const event = fakeEvent({
			'/api/auth/me': json({ user: { id: 'u1', nome: 'Ana' }, active_clinic_id: 'c1' })
		});
		await expect(load(event)).rejects.toMatchObject({
			status: 307,
			location: '/agenda'
		});
	});
});
