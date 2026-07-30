import { describe, it, expect, vi, beforeEach } from 'vitest';

const ch = vi.hoisted(() => ({ fetchClinicHours: vi.fn() }));
vi.mock('$lib/server/clinic-hours', () => ch);

const m = vi.hoisted(() => ({
	fetchProfessional: vi.fn(),
	updateProfessional: vi.fn(),
	parseIds: vi.fn((): string[] => []),
	runProfessionalSave: vi.fn()
}));
vi.mock('$lib/server/professionals', () => m);

import { load, actions } from './+page.server';

function ev(fields: Record<string, string> = {}, id = 'p1') {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { params: { id }, request: { formData: async () => fd } } as never;
}

beforeEach(() => {
	[...Object.values(ch), ...Object.values(m)].forEach((fn) => fn.mockReset());
	m.parseIds.mockReturnValue([]);
});

describe('load', () => {
	it('profissional + expediente → devolve os dois', async () => {
		m.fetchProfessional.mockResolvedValueOnce({ status: 200, professional: { id: 'p1', nome: 'M' } });
		ch.fetchClinicHours.mockResolvedValueOnce({ status: 200, data: { clinic_hours: { '1': [] } } });
		const r = (await load({ params: { id: 'p1' } } as never)) as { professional: { id: string } };
		expect(r.professional.id).toBe('p1');
	});

	it('profissional inexistente → 404', async () => {
		m.fetchProfessional.mockResolvedValueOnce({ status: 404, professional: null });
		ch.fetchClinicHours.mockResolvedValueOnce({ status: 200, data: { clinic_hours: {} } });
		await expect(load({ params: { id: 'nope' } } as never)).rejects.toMatchObject({ status: 404 });
	});
});

describe('action save', () => {
	it('runProfessionalSave ok → redireciona; usa a situação/ids originais do form', async () => {
		m.runProfessionalSave.mockResolvedValueOnce({ ok: true });
		m.parseIds.mockReturnValueOnce(['e1']);

		await expect(
			actions.save(ev({ ficha: '{}', days: '[]', original_ativo: 'false', original_exception_ids: '["e1"]' }))
		).rejects.toMatchObject({ status: 303, location: '/profissionais' });

		expect(m.runProfessionalSave).toHaveBeenCalledWith(
			expect.anything(),
			expect.anything(),
			expect.objectContaining({ professionalId: 'p1', originalActive: false, originalExceptionIds: ['e1'] })
		);
	});

	it('runProfessionalSave falha → fail com status', async () => {
		m.runProfessionalSave.mockResolvedValueOnce({ ok: false, status: 400, error: 'x' });
		expect(await actions.save(ev())).toMatchObject({ status: 400 });
	});
});
