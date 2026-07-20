import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({
	apiFetch: vi.fn(),
	apiPublicOrigin: vi.fn(() => 'http://localhost:4010')
}));

vi.mock('$lib/server/api', () => m);

import { GET } from './+server';

const event = {} as never;

beforeEach(() => {
	m.apiFetch.mockReset();
	m.apiPublicOrigin.mockReturnValue('http://localhost:4010');
});

function apiResponde(status: number, body: unknown) {
	m.apiFetch.mockResolvedValue({
		ok: status >= 200 && status < 300,
		status,
		json: async () => body
	});
}

describe('GET /api/realtime/token', () => {
	it('devolve o token da API acrescido da origem pública', async () => {
		apiResponde(200, { token: 'tok', expires_at: '2026-07-20T12:15:00Z', clinic_id: 'c1' });

		const res = await GET(event);

		expect(await res.json()).toEqual({
			token: 'tok',
			expires_at: '2026-07-20T12:15:00Z',
			clinic_id: 'c1',
			// Sem isto o cliente não teria para onde abrir o socket: a origem é env privada do
			// BFF, e o WebSocket é a exceção ao ADR-005 (fala direto com a API).
			origin: 'http://localhost:4010'
		});
	});

	it('pede pelo caminho certo da API', async () => {
		apiResponde(200, { token: 't', expires_at: 'x', clinic_id: 'c1' });
		await GET(event);

		expect(m.apiFetch.mock.calls[0][1]).toBe('/api/realtime/token');
	});

	it('sem sessão repassa 401 e NÃO devolve corpo da API', async () => {
		apiResponde(401, { error: 'unauthenticated', detalhe: 'interno' });

		const res = await GET(event);

		expect(res.status).toBe(401);
		expect(await res.json()).toEqual({ error: 'unavailable' });
	});

	it('sem clínica ativa repassa 409', async () => {
		apiResponde(409, { error: 'no_active_clinic' });
		expect((await GET(event)).status).toBe(409);
	});

	it('API fora do ar vira 503 — a agenda degrada para estática, não quebra', async () => {
		m.apiFetch.mockRejectedValue(new Error('econnrefused'));

		const res = await GET(event);

		expect(res.status).toBe(503);
		expect(await res.json()).toEqual({ error: 'unavailable' });
	});
});
