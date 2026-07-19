import { describe, it, expect, vi, beforeEach } from 'vitest';

const pf = vi.hoisted(() => ({ fetchProfessionals: vi.fn() }));
vi.mock('$lib/server/professionals', () => pf);

const m = vi.hoisted(() => ({
	fetchPatient: vi.fn(),
	updatePatient: vi.fn(),
	runPatientSave: vi.fn()
}));
vi.mock('$lib/server/patients', () => m);

import { load, actions } from './+page.server';

function ev(fields: Record<string, string> = {}) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd }, params: { id: 'pac1' } } as never;
}

beforeEach(() => [...Object.values(pf), ...Object.values(m)].forEach((fn) => fn.mockReset()));

describe('load', () => {
	// Sem carrega-tudo: o aviso de duplicado virou lookup pontual, então o load só traz a ficha
	// e o diretório.
	it('200 → paciente + diretório', async () => {
		m.fetchPatient.mockResolvedValueOnce({ status: 200, patient: { id: 'pac1', nome: 'Mari' } });
		pf.fetchProfessionals.mockResolvedValueOnce({ data: { professionals: [] } });
		const r = (await load({ params: { id: 'pac1' } } as never)) as { patient: { nome: string } };
		expect(r.patient.nome).toBe('Mari');
	});
	it('não encontrado → 404', async () => {
		m.fetchPatient.mockResolvedValueOnce({ status: 404, patient: null });
		pf.fetchProfessionals.mockResolvedValueOnce({ data: null });
		await expect(load({ params: { id: 'x' } } as never)).rejects.toMatchObject({ status: 404 });
	});
});

describe('action save', () => {
	it('ok → redireciona para a ficha', async () => {
		m.runPatientSave.mockResolvedValueOnce({ ok: true });
		await expect(actions.save(ev({ ficha: '{}' }))).rejects.toMatchObject({
			status: 303,
			location: '/pacientes/pac1'
		});
	});
	it('falha → fail com status', async () => {
		m.runPatientSave.mockResolvedValueOnce({ ok: false, status: 422, error: 'ruim' });
		expect(await actions.save(ev())).toMatchObject({ status: 422 });
	});
});
