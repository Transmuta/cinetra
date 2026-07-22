import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => m);

import { fetchReports } from './reports';

const event = {} as never;

function res(status: number, body?: unknown) {
	return { ok: status >= 200 && status < 300, status, json: async () => body };
}

beforeEach(() => m.apiFetch.mockReset());

describe('fetchReports', () => {
	it('monta a query só com os parâmetros presentes', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, {}));

		await fetchReports(event, {
			date_from: '2026-06-01',
			date_to: '2026-06-30',
			professional_id: 'p1'
		});

		const [, path] = m.apiFetch.mock.calls[0];
		expect(path).toContain('/api/reports/summary?');
		expect(path).toContain('date_from=2026-06-01');
		expect(path).toContain('date_to=2026-06-30');
		expect(path).toContain('professional_id=p1');
	});

	it('professional_id ausente não entra na URL', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, {}));
		await fetchReports(event, { date_from: '2026-06-01', date_to: '2026-06-30' });
		expect(m.apiFetch.mock.calls[0][1]).not.toContain('professional_id');
	});

	it('200 → devolve os dados', async () => {
		const data = { totals: { atendimentos: 3 } };
		m.apiFetch.mockResolvedValueOnce(res(200, data));

		const out = await fetchReports(event, { date_from: 'a', date_to: 'b' });
		expect(out).toEqual({ status: 200, data });
	});

	it('não-2xx → data null com o status', async () => {
		m.apiFetch.mockResolvedValueOnce(res(422));
		const out = await fetchReports(event, { date_from: 'a', date_to: 'b' });
		expect(out).toEqual({ status: 422, data: null });
	});

	it('falha de rede → status 0, data null', async () => {
		m.apiFetch.mockRejectedValueOnce(new Error('down'));
		const out = await fetchReports(event, { date_from: 'a', date_to: 'b' });
		expect(out).toEqual({ status: 0, data: null });
	});
});
