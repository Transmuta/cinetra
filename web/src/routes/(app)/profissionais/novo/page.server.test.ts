import { describe, it, expect, vi, beforeEach } from 'vitest';

const ch = vi.hoisted(() => ({ fetchClinicHours: vi.fn() }));
vi.mock('$lib/server/clinic-hours', () => ch);

const m = vi.hoisted(() => ({
	createProfessional: vi.fn(),
	runProfessionalSave: vi.fn()
}));
vi.mock('$lib/server/professionals', () => m);

import { load, actions } from './+page.server';

function ev(fields: Record<string, string> = {}) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

beforeEach(() => [...Object.values(ch), ...Object.values(m)].forEach((fn) => fn.mockReset()));

describe('load', () => {
	it('converte o expediente da clínica em linhas', async () => {
		ch.fetchClinicHours.mockResolvedValueOnce({ status: 200, data: { clinic_hours: { '1': [['08:00', '12:00']] } } });
		const r = (await load({} as never)) as { clinicHours: { dow: number; periods: unknown }[] };
		expect(r.clinicHours).toEqual([{ dow: 1, modo: null, periods: [['08:00', '12:00']] }]);
	});
	it('sem data → error', async () => {
		ch.fetchClinicHours.mockResolvedValueOnce({ status: 502, data: null });
		await expect(load({} as never)).rejects.toMatchObject({ status: 502 });
	});
});

describe('action save', () => {
	it('runProfessionalSave ok → redireciona', async () => {
		m.runProfessionalSave.mockResolvedValueOnce({ ok: true });
		await expect(actions.save(ev({ ficha: '{}', days: '[]' }))).rejects.toMatchObject({
			status: 303,
			location: '/profissionais'
		});
		// persist deve ser o create (novo nasce ativo, sem ids originais)
		expect(m.runProfessionalSave).toHaveBeenCalledWith(
			expect.anything(),
			expect.anything(),
			expect.objectContaining({ originalActive: true, originalExceptionIds: [] })
		);
	});

	it('runProfessionalSave falha → fail com status', async () => {
		m.runProfessionalSave.mockResolvedValueOnce({ ok: false, status: 422, error: 'ruim' });
		expect(await actions.save(ev())).toMatchObject({ status: 422 });
	});
});
