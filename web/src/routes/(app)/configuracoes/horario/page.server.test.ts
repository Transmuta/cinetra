import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({
	fetchClinicHours: vi.fn(),
	updateClinicHours: vi.fn()
}));
vi.mock('$lib/server/clinic-hours', () => m);

import { load, actions } from './+page.server';
import type { WeekHours } from '$lib/scheduling';

type LoadOk = { clinicHours: WeekHours };
const runLoad = async (): Promise<LoadOk> => (await load({} as never)) as LoadOk;

function ev(fields: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

const week: WeekHours = { '1': [['08:00', '12:00']], '0': [] };

beforeEach(() => Object.values(m).forEach((fn) => fn.mockReset()));

describe('load', () => {
	it('200 → devolve o expediente', async () => {
		m.fetchClinicHours.mockResolvedValueOnce({ status: 200, data: { clinic_hours: week } });
		expect((await runLoad()).clinicHours).toEqual(week);
	});

	it('sem data → error de gateway', async () => {
		m.fetchClinicHours.mockResolvedValueOnce({ status: 502, data: null });
		await expect(load({} as never)).rejects.toMatchObject({ status: 502 });
	});
});

describe('action save', () => {
	it('semana válida → chama updateClinicHours e devolve ok', async () => {
		m.updateClinicHours.mockResolvedValueOnce({ ok: true, status: 200 });
		const r = await actions.save(ev({ clinic_hours: JSON.stringify(week) }));
		expect(r).toEqual({ ok: true });
		expect(m.updateClinicHours).toHaveBeenCalledWith(expect.anything(), week, false);
	});

	it('JSON malformado → fail 400 sem tocar na API', async () => {
		const r = await actions.save(ev({ clinic_hours: '{ nope' }));
		expect(r).toMatchObject({ status: 400 });
		expect(m.updateClinicHours).not.toHaveBeenCalled();
	});

	it('JSON que não é objeto (array) → fail 400', async () => {
		const r = await actions.save(ev({ clinic_hours: '[]' }));
		expect(r).toMatchObject({ status: 400 });
		expect(m.updateClinicHours).not.toHaveBeenCalled();
	});

	it('API recusa (422) → fail com o status', async () => {
		m.updateClinicHours.mockResolvedValueOnce({ ok: false, status: 422, error: 'ruim' });
		const r = await actions.save(ev({ clinic_hours: JSON.stringify(week) }));
		expect(r).toMatchObject({ status: 422 });
	});
});
