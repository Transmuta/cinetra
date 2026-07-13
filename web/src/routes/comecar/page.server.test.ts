import { describe, it, expect, vi, beforeEach } from 'vitest';
import { redirect } from '@sveltejs/kit';

const requireSession = vi.fn();
const onboardClinic = vi.fn();

vi.mock('$lib/server/auth', () => ({ requireSession: (...a: unknown[]) => requireSession(...a) }));
vi.mock('$lib/server/clinics', () => ({ onboardClinic: (...a: unknown[]) => onboardClinic(...a) }));

import { load, actions } from './+page.server';

beforeEach(() => {
	requireSession.mockReset();
	onboardClinic.mockReset();
});

// Evento com um FormData no corpo (para a action de submit).
function formEvent(fields: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	const request = new Request('http://web/comecar', { method: 'POST', body: fd });
	return { request } as never;
}

describe('load /comecar (guarda do onboarding)', () => {
	it('sem sessão → propaga o redirect de requireSession (/entrar)', async () => {
		requireSession.mockImplementation(async () => redirect(303, '/entrar'));
		await expect(load({} as never)).rejects.toMatchObject({ status: 303, location: '/entrar' });
	});

	it('já tem clínica ativa → redirect 303 para a home', async () => {
		requireSession.mockResolvedValue({ active_clinic_id: 'c1', user: { nome: 'Ana' } });
		await expect(load({} as never)).rejects.toMatchObject({ status: 303, location: '/' });
	});

	it('logado sem clínica → mostra o form (devolve o nome para o cumprimento)', async () => {
		requireSession.mockResolvedValue({ active_clinic_id: null, user: { nome: 'Ana Paula' } });
		expect(await load({} as never)).toEqual({ nome: 'Ana Paula' });
	});
});

describe('action default /comecar (cria a clínica)', () => {
	it('nome vazio → fail(400) e NÃO chama a API', async () => {
		const result = (await actions.default(formEvent({ nome: '   ' }))) as {
			status: number;
			data: { error: string };
		};
		expect(result.status).toBe(400);
		expect(result.data.error).toMatch(/nome/i);
		expect(onboardClinic).not.toHaveBeenCalled();
	});

	it('sucesso → cria (com trim) e redirect 303 para a home', async () => {
		onboardClinic.mockResolvedValue({ ok: true, status: 201 });
		await expect(actions.default(formEvent({ nome: '  Studio Movimento  ' }))).rejects.toMatchObject({
			status: 303,
			location: '/'
		});
		expect(onboardClinic).toHaveBeenCalledWith(expect.anything(), 'Studio Movimento');
	});

	it('falha da API → fail com a mensagem e sem redirect', async () => {
		onboardClinic.mockResolvedValue({ ok: false, status: 422, error: 'Confira o nome da clínica.' });
		const result = (await actions.default(formEvent({ nome: 'X' }))) as {
			status: number;
			data: { error: string };
		};
		expect(result.status).toBe(422);
		expect(result.data.error).toMatch(/nome/i);
	});
});
