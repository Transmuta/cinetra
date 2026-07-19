import { describe, it, expect, vi, beforeEach } from 'vitest';

const pf = vi.hoisted(() => ({ fetchProfessionals: vi.fn() }));
vi.mock('$lib/server/professionals', () => pf);

const m = vi.hoisted(() => ({
	createPatient: vi.fn(),
	runPatientSave: vi.fn()
}));
vi.mock('$lib/server/patients', () => m);

import { load, actions } from './+page.server';

function ev(fields: Record<string, string> = {}) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

beforeEach(() => [...Object.values(pf), ...Object.values(m)].forEach((fn) => fn.mockReset()));

describe('load', () => {
	// O cadastro inteiro NÃO é mais carregado aqui: o aviso de duplicado virou lookup pontual.
	it('devolve só o diretório (chips de profissional preferido)', async () => {
		pf.fetchProfessionals.mockResolvedValueOnce({ data: { professionals: [{ id: 'p1' }] } });
		const r = (await load({} as never)) as { professionals: unknown[] };
		expect(r).toEqual({ professionals: [{ id: 'p1' }] });
	});
	it('tolera falha de carga (lista vazia)', async () => {
		pf.fetchProfessionals.mockResolvedValueOnce({ data: null });
		expect(await load({} as never)).toEqual({ professionals: [] });
	});
});

describe('action save', () => {
	it('runPatientSave ok → redireciona', async () => {
		m.runPatientSave.mockResolvedValueOnce({ ok: true });
		await expect(actions.save(ev({ ficha: '{}' }))).rejects.toMatchObject({
			status: 303,
			location: '/pacientes'
		});
	});
	it('runPatientSave falha → fail com status', async () => {
		m.runPatientSave.mockResolvedValueOnce({ ok: false, status: 422, error: 'ruim' });
		expect(await actions.save(ev())).toMatchObject({ status: 422 });
	});
});
