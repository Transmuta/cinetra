import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => m);

import { fetchAudit } from './audit';

const event = {} as never;

function res(status: number, body?: unknown) {
	return { ok: status >= 200 && status < 300, status, json: async () => body };
}

beforeEach(() => m.apiFetch.mockReset());

describe('fetchAudit', () => {
	it('monta a query string só com os parâmetros presentes', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, { entries: [], page: {} }));

		await fetchAudit(event, { resource: 'attendance', limit: 50, offset: 100, action: '' });

		const [, path] = m.apiFetch.mock.calls[0];
		expect(path).toContain('/api/audit?');
		expect(path).toContain('resource=attendance');
		expect(path).toContain('limit=50');
		expect(path).toContain('offset=100');
		// `action: ''` é vazio → não entra na URL.
		expect(path).not.toContain('action=');
	});

	it('sem parâmetros, chama o endpoint sem query string', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, { entries: [], page: {} }));
		await fetchAudit(event, {});
		expect(m.apiFetch.mock.calls[0][1]).toBe('/api/audit');
	});

	it('200 → devolve os dados', async () => {
		const data = { entries: [{ id: 'v1' }], page: { total: 1 } };
		m.apiFetch.mockResolvedValueOnce(res(200, data));

		const out = await fetchAudit(event, {});
		expect(out).toEqual({ status: 200, data });
	});

	it('403 (ou qualquer não-2xx) → data null com o status', async () => {
		m.apiFetch.mockResolvedValueOnce(res(403));
		const out = await fetchAudit(event, {});
		expect(out).toEqual({ status: 403, data: null });
	});

	it('falha de rede → status 0, data null', async () => {
		m.apiFetch.mockRejectedValueOnce(new Error('down'));
		const out = await fetchAudit(event, {});
		expect(out).toEqual({ status: 0, data: null });
	});
});
