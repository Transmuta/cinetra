import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({
	fetchClinic: vi.fn(),
	updateClinic: vi.fn()
}));
vi.mock('$lib/server/clinics', () => m);

import { load, actions } from './+page.server';

const clinic = { id: 'c1', nome: 'Clínica Vida', cnpj: null, endereco: null };

const runLoad = async () => (await load({} as never)) as { clinic: typeof clinic };

function ev(fields: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

beforeEach(() => Object.values(m).forEach((fn) => fn.mockReset()));

describe('load', () => {
	it('200 → devolve a clínica', async () => {
		m.fetchClinic.mockResolvedValueOnce({ status: 200, data: { clinic } });
		expect((await runLoad()).clinic).toEqual(clinic);
	});

	it('sem data → error de gateway', async () => {
		m.fetchClinic.mockResolvedValueOnce({ status: 403, data: null });
		await expect(load({} as never)).rejects.toMatchObject({ status: 403 });
	});
});

describe('action save', () => {
	it('nome preenchido → chama updateClinic com nome/cnpj/endereço e devolve ok', async () => {
		m.updateClinic.mockResolvedValueOnce({ ok: true, status: 200 });

		const r = await actions.save(
			ev({ nome: '  Clínica Vida  ', cnpj: '12.ABC.345/01DE-35', endereco: '  Rua X  ' })
		);

		expect(r).toEqual({ ok: true });
		expect(m.updateClinic).toHaveBeenCalledWith(expect.anything(), {
			nome: 'Clínica Vida',
			cnpj: '12.ABC.345/01DE-35',
			endereco: 'Rua X'
		});
	});

	it('nome vazio → fail 400 sem tocar na API', async () => {
		const r = await actions.save(ev({ nome: '   ' }));
		expect(r).toMatchObject({ status: 400 });
		expect(m.updateClinic).not.toHaveBeenCalled();
	});

	it('API recusa (422 CNPJ inválido) → fail com o status', async () => {
		m.updateClinic.mockResolvedValueOnce({ ok: false, status: 422, error: 'ruim' });
		const r = await actions.save(ev({ nome: 'X', cnpj: 'xx', endereco: '' }));
		expect(r).toMatchObject({ status: 422 });
	});
});
