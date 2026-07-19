import { describe, it, expect, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({ env: {} }));

import { load } from './+page.server';

function json(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

// Roteia o fetch do BFF por fragmento de path (só /api/auth/me neste load).
function fakeEvent(routes: Record<string, Response>) {
	const fetch = vi.fn((url: string) => {
		for (const [frag, res] of Object.entries(routes)) {
			if (url.includes(frag)) return Promise.resolve(res);
		}
		return Promise.resolve(new Response('', { status: 404 }));
	});
	return { fetch, cookies: { get: () => undefined } } as never;
}

// A raiz é a landing pública: deslogado renderiza; logado é mandado para onde pertence.
describe('load / (landing pública)', () => {
	it('sem sessão → renderiza a landing (não redireciona)', async () => {
		const event = fakeEvent({ '/api/auth/me': json({ error: 'not_authenticated' }, 401) });
		await expect(load(event)).resolves.toEqual({});
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
