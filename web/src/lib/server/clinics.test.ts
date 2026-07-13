import { describe, it, expect, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({ env: {} }));

import { onboardClinic } from './clinics';

function json(body: unknown, status: number) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

function event(fetchImpl: ReturnType<typeof vi.fn>) {
	return { fetch: fetchImpl, cookies: { get: () => undefined } } as never;
}

describe('onboardClinic (BFF do onboarding)', () => {
	it('201 → ok e faz POST /api/clinics com o nome no corpo', async () => {
		const fetch = vi.fn().mockResolvedValue(json({ clinic: { id: 'c1', nome: 'X' } }, 201));
		const res = await onboardClinic(event(fetch), 'Studio Movimento');

		expect(res).toEqual({ ok: true, status: 201 });
		const [url, init] = fetch.mock.calls[0];
		expect(url).toBe('http://localhost:4000/api/clinics');
		expect(init.method).toBe('POST');
		expect(JSON.parse(init.body as string)).toEqual({ nome: 'Studio Movimento' });
	});

	it('422 → mensagem sobre o nome', async () => {
		const res = await onboardClinic(event(vi.fn().mockResolvedValue(json({ error: 'invalid' }, 422))), 'X');
		expect(res).toMatchObject({ ok: false, status: 422 });
		expect(res.error).toMatch(/nome/i);
	});

	it('401 → mensagem de sessão expirada', async () => {
		const res = await onboardClinic(event(vi.fn().mockResolvedValue(json({}, 401))), 'X');
		expect(res).toMatchObject({ ok: false, status: 401 });
		expect(res.error).toMatch(/sess/i);
	});

	it('outro status de erro → mensagem genérica', async () => {
		const res = await onboardClinic(event(vi.fn().mockResolvedValue(json({}, 500))), 'X');
		expect(res).toMatchObject({ ok: false, status: 500 });
		expect(res.error).toMatch(/cl[íi]nica/i);
	});

	it('exceção de rede → falha de conexão (status 0)', async () => {
		const res = await onboardClinic(event(vi.fn().mockRejectedValue(new Error('ECONNREFUSED'))), 'X');
		expect(res).toMatchObject({ ok: false, status: 0 });
		expect(res.error).toMatch(/conex/i);
	});
});
