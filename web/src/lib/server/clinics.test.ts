import { describe, it, expect, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({ env: {} }));

const reemitSession = vi.fn();
vi.mock('./api', async (importOriginal) => {
	const actual = await importOriginal<typeof import('./api')>();
	return { ...actual, reemitSession: (...a: unknown[]) => reemitSession(...a) };
});

import { onboardClinic, switchTenant, fetchClinic, updateClinic } from './clinics';

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
	it('201 → ok, devolve o id da clínica e faz POST /api/clinics com o nome no corpo', async () => {
		const fetch = vi.fn().mockResolvedValue(json({ clinic: { id: 'c1', nome: 'X' } }, 201));
		const res = await onboardClinic(event(fetch), 'Studio Movimento');

		expect(res).toEqual({ ok: true, status: 201, clinicId: 'c1' });
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

describe('switchTenant (troca de tenant ativo)', () => {
	it('ok → POST /api/auth/switch-tenant com clinic_id e reemite a sessão', async () => {
		reemitSession.mockReset();
		const fetch = vi.fn().mockResolvedValue(json({ active_clinic_id: 'c2' }, 200));
		const res = await switchTenant(event(fetch), 'c2');

		expect(res).toEqual({ ok: true, status: 200 });
		const [url, init] = fetch.mock.calls[0];
		expect(url).toBe('http://localhost:4000/api/auth/switch-tenant');
		expect(init.method).toBe('POST');
		expect(JSON.parse(init.body as string)).toEqual({ clinic_id: 'c2' });
		expect(reemitSession).toHaveBeenCalledOnce();
	});

	it('erro da API → não reemite e devolve ok=false', async () => {
		reemitSession.mockReset();
		const res = await switchTenant(event(vi.fn().mockResolvedValue(json({ error: 'no_active_membership' }, 403))), 'c9');
		expect(res).toMatchObject({ ok: false, status: 403 });
		expect(reemitSession).not.toHaveBeenCalled();
	});

	it('exceção de rede → ok=false status 0', async () => {
		reemitSession.mockReset();
		const res = await switchTenant(event(vi.fn().mockRejectedValue(new Error('down'))), 'c2');
		expect(res).toMatchObject({ ok: false, status: 0 });
	});
});

describe('fetchClinic (dados da clínica ativa)', () => {
	it('200 → GET /api/clinic e devolve o clinic', async () => {
		const clinic = { id: 'c1', nome: 'Clínica Vida', cnpj: '12ABC34501DE35', endereco: 'Rua X' };
		const fetch = vi.fn().mockResolvedValue(json({ clinic }, 200));
		const res = await fetchClinic(event(fetch));

		expect(res).toEqual({ status: 200, data: { clinic } });
		expect(fetch.mock.calls[0][0]).toBe('http://localhost:4000/api/clinic');
	});

	it('erro → data null', async () => {
		const res = await fetchClinic(event(vi.fn().mockResolvedValue(json({}, 403))));
		expect(res).toEqual({ status: 403, data: null });
	});

	it('falha de rede não explode o load', async () => {
		const res = await fetchClinic(event(vi.fn().mockRejectedValue(new Error('down'))));
		expect(res).toEqual({ status: 0, data: null });
	});
});

describe('updateClinic (edição da clínica)', () => {
	it('PATCH /api/clinic com o corpo whitelisted', async () => {
		const fetch = vi.fn().mockResolvedValue(json({ clinic: {} }, 200));
		const input = { nome: 'Nova', cnpj: '12.ABC.345/01DE-35', endereco: 'Rua Y' };
		const res = await updateClinic(event(fetch), input);

		expect(res).toEqual({ ok: true, status: 200 });
		const [url, init] = fetch.mock.calls[0];
		expect(url).toBe('http://localhost:4000/api/clinic');
		expect(init.method).toBe('PATCH');
		expect(JSON.parse(init.body as string)).toEqual(input);
	});

	it('422 (CNPJ inválido) → mensagem de dados inválidos', async () => {
		const res = await updateClinic(
			event(vi.fn().mockResolvedValue(json({ error: 'invalid', details: [] }, 422))),
			{ cnpj: 'xx' }
		);
		expect(res.error).toMatch(/inválidos/i);
	});

	it('403 (papel errado) → mensagem de permissão', async () => {
		const res = await updateClinic(event(vi.fn().mockResolvedValue(json({}, 403))), { nome: 'X' });
		expect(res.error).toMatch(/permissão/i);
	});
});
