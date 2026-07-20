import { describe, it, expect, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({ env: {} }));

import {
	requestMagicLink,
	landingPath,
	requireSession,
	redirectIfAuthenticated
} from './auth';
import { SESSION_COOKIE } from './api';
import { meFixture } from '$lib/testing/fixtures';

function json(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

// Evento com o /me (via loadMe) resolvendo para `res`. Sem cookie de sessão no repasse.
function meEvent(res: Response) {
	return { fetch: vi.fn().mockResolvedValue(res), cookies: { get: () => undefined } } as never;
}

function fakeEvent(email: string, fetchImpl?: ReturnType<typeof vi.fn>, nome?: string) {
	const fd = new FormData();
	fd.set('email', email);
	if (nome !== undefined) fd.set('nome', nome);
	const request = new Request('http://web/entrar', { method: 'POST', body: fd });
	const fetch = fetchImpl ?? vi.fn().mockResolvedValue(new Response('{"ok":true}'));
	return {
		event: { request, fetch, cookies: { get: () => undefined } } as never,
		fetch
	};
}

describe('requestMagicLink (action compartilhada, resposta neutra)', () => {
	it('e-mail vazio: fail(400) e NÃO chama a API', async () => {
		const { event, fetch } = fakeEvent('   ');
		const result = (await requestMagicLink(event)) as { status: number; data: { error: string } };

		expect(result.status).toBe(400);
		expect(result.data.error).toMatch(/e-mail/i);
		expect(fetch).not.toHaveBeenCalled();
	});

	it('form sem o campo email: também fail(400) sem chamar a API', async () => {
		const request = new Request('http://web/entrar', { method: 'POST', body: new FormData() });
		const fetch = vi.fn();
		const event = { request, fetch, cookies: { get: () => undefined } } as never;

		const result = (await requestMagicLink(event)) as { status: number };
		expect(result.status).toBe(400);
		expect(fetch).not.toHaveBeenCalled();
	});

	it('e-mail válido: POST /api/auth/magic-link e retorna {sent:true}', async () => {
		const { event, fetch } = fakeEvent('ana@example.com');
		const result = await requestMagicLink(event);

		expect(result).toEqual({ sent: true, email: 'ana@example.com' });
		const [url, init] = fetch.mock.calls[0];
		expect(url).toBe('http://localhost:4000/api/auth/magic-link');
		expect(init.method).toBe('POST');
		expect(JSON.parse(init.body as string)).toEqual({ email: 'ana@example.com' });
	});

	it('cadastro (register=true) com nome: inclui nome e register no corpo', async () => {
		const { event, fetch } = fakeEvent('ana@example.com', undefined, '  Ana Paula  ');
		const result = await requestMagicLink(event, true);

		expect(result).toEqual({ sent: true, email: 'ana@example.com' });
		expect(JSON.parse(fetch.mock.calls[0][1].body as string)).toEqual({
			email: 'ana@example.com',
			nome: 'Ana Paula',
			register: true
		});
	});

	it('login (default) sem nome: corpo só com email, SEM register nem nome', async () => {
		const { event, fetch } = fakeEvent('ana@example.com', undefined, '   ');
		await requestMagicLink(event);

		expect(JSON.parse(fetch.mock.calls[0][1].body as string)).toEqual({ email: 'ana@example.com' });
	});

	it('cadastro (register=true) sem nome: corpo carrega register mas não nome', async () => {
		const { event, fetch } = fakeEvent('ana@example.com', undefined, '   ');
		await requestMagicLink(event, true);

		expect(JSON.parse(fetch.mock.calls[0][1].body as string)).toEqual({
			email: 'ana@example.com',
			register: true
		});
	});

	it('faz trim do e-mail antes de mandar', async () => {
		const { event, fetch } = fakeEvent('  bruno@example.com  ');
		const result = await requestMagicLink(event);

		expect(result).toEqual({ sent: true, email: 'bruno@example.com' });
		expect(JSON.parse(fetch.mock.calls[0][1].body as string)).toEqual({ email: 'bruno@example.com' });
	});

	it('falha de rede não vaza: ainda retorna {sent:true} (neutro)', async () => {
		const failing = vi.fn().mockRejectedValue(new Error('ECONNREFUSED'));
		const { event } = fakeEvent('carla@example.com', failing);

		const result = await requestMagicLink(event);
		expect(result).toEqual({ sent: true, email: 'carla@example.com' });
	});

	it('não repassa cookie de sessão inexistente (SESSION_COOKIE ausente)', async () => {
		const { event, fetch } = fakeEvent('d@example.com');
		await requestMagicLink(event);
		expect((fetch.mock.calls[0][1].headers as Headers).get('cookie')).toBeNull();
		expect(SESSION_COOKIE).toBe('_api_key');
	});
});

describe('landingPath (destino pós-login)', () => {
	it('com clínica ativa → home do app (shell)', () => {
		expect(landingPath(meFixture({ active_clinic_id: 'c1' }))).toBe('/agenda');
	});

	it('sem clínica ativa → onboarding', () => {
		expect(landingPath(meFixture({ active_clinic_id: null }))).toBe('/comecar');
	});
});

describe('requireSession (guarda de páginas protegidas)', () => {
	it('sem sessão (401 no /me) → redirect 303 para /entrar', async () => {
		await expect(requireSession(meEvent(json({ error: 'x' }, 401)))).rejects.toMatchObject({
			status: 303,
			location: '/entrar'
		});
	});

	it('com sessão → devolve o me carregado', async () => {
		const me = { user: { nome: 'Ana' }, active_clinic_id: 'c1' };
		expect(await requireSession(meEvent(json(me)))).toMatchObject({ active_clinic_id: 'c1' });
	});
});

describe('redirectIfAuthenticated (guarda das páginas de auth)', () => {
	it('logado com clínica → redirect 303 para a home do app (shell)', async () => {
		const event = meEvent(json({ user: { nome: 'Ana' }, active_clinic_id: 'c1' }));
		await expect(redirectIfAuthenticated(event)).rejects.toMatchObject({
			status: 303,
			location: '/agenda'
		});
	});

	it('logado sem clínica → redirect 303 para /comecar', async () => {
		const event = meEvent(json({ user: { nome: 'Ana' }, active_clinic_id: null }));
		await expect(redirectIfAuthenticated(event)).rejects.toMatchObject({
			status: 303,
			location: '/comecar'
		});
	});

	it('sem sessão → não redireciona (deixa ver o formulário)', async () => {
		await expect(redirectIfAuthenticated(meEvent(json({ error: 'x' }, 401)))).resolves.toBeUndefined();
	});
});
