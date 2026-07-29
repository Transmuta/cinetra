import { describe, it, expect, vi, beforeEach } from 'vitest';

const api = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => api);

import { fetchAccessMatrix } from './access-matrix';

function res(status: number, body?: unknown): Response {
	return { ok: status >= 200 && status < 300, status, json: async () => body } as unknown as Response;
}

const event = {} as never;

beforeEach(() => api.apiFetch.mockReset());

describe('fetchAccessMatrix', () => {
	it('200 → papéis e áreas', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { papeis: ['owner'], areas: [{ id: 'agenda' }] }));
		const r = await fetchAccessMatrix(event);
		expect(r.status).toBe(200);
		expect(r.data?.areas).toHaveLength(1);
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/access-matrix');
	});

	it('erro HTTP → data null (a matriz é apoio, não a tela)', async () => {
		api.apiFetch.mockResolvedValueOnce(res(502));
		expect(await fetchAccessMatrix(event)).toEqual({ status: 502, data: null });
	});

	it('rede fora → status 0', async () => {
		api.apiFetch.mockRejectedValueOnce(new Error('rede'));
		expect(await fetchAccessMatrix(event)).toEqual({ status: 0, data: null });
	});
});
