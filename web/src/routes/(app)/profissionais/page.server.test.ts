import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ fetchProfessionals: vi.fn() }));
vi.mock('$lib/server/professionals', () => m);

import { load } from './+page.server';

beforeEach(() => m.fetchProfessionals.mockReset());

describe('load', () => {
	it('200 → profissionais + expediente da clínica', async () => {
		m.fetchProfessionals.mockResolvedValueOnce({
			status: 200,
			data: { professionals: [{ id: 'p1' }], clinic_hours: [{ dow: 1, modo: null, periods: [] }] }
		});
		const r = (await load({} as never)) as { professionals: unknown[]; clinicHours: unknown[] };
		expect(r.professionals).toHaveLength(1);
		expect(r.clinicHours).toHaveLength(1);
	});

	it('sem data → error de gateway', async () => {
		m.fetchProfessionals.mockResolvedValueOnce({ status: 502, data: null });
		await expect(load({} as never)).rejects.toMatchObject({ status: 502 });
	});
});
