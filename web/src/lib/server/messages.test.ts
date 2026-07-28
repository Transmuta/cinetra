import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => m);

const mut = vi.hoisted(() => ({ mutate: vi.fn() }));
vi.mock('./mutate', () => mut);

import { fetchMessages, sendConfirmation } from './messages';

const event = {} as never;

function res(status: number, body?: unknown) {
	return { ok: status >= 200 && status < 300, status, json: async () => body };
}

beforeEach(() => {
	m.apiFetch.mockReset();
	mut.mutate.mockReset();
});

describe('fetchMessages', () => {
	it('200 → devolve a timeline', async () => {
		const data = { participantes: [{ attendanceId: 'a1' }] };
		m.apiFetch.mockResolvedValueOnce(res(200, data));

		expect(await fetchMessages(event, 'ap1')).toEqual({ status: 200, data });
		expect(m.apiFetch.mock.calls[0][1]).toBe('/api/appointments/ap1/messages');
	});

	it('erro da API vira data nula, sem levantar', async () => {
		// O drawer precisa abrir mesmo com a comunicação fora do ar: o bloco é o assunto da tela.
		m.apiFetch.mockResolvedValueOnce(res(500));

		expect(await fetchMessages(event, 'ap1')).toEqual({ status: 500, data: null });
	});

	it('rede caída vira status 0', async () => {
		m.apiFetch.mockRejectedValueOnce(new Error('offline'));

		expect(await fetchMessages(event, 'ap1')).toEqual({ status: 0, data: null });
	});
});

describe('sendConfirmation', () => {
	it('sem paciente, manda corpo vazio (vale para todos os participantes)', async () => {
		mut.mutate.mockResolvedValueOnce({ ok: true, status: 201 });

		await sendConfirmation(event, 'ap1');

		expect(mut.mutate).toHaveBeenCalledWith(event, '/api/appointments/ap1/messages', 'POST', {});
	});

	it('com paciente, recorta um participante', async () => {
		// Numa turma, reenviar para quem falhou não pode disparar para os outros três.
		mut.mutate.mockResolvedValueOnce({ ok: true, status: 201 });

		await sendConfirmation(event, 'ap1', 'p9');

		expect(mut.mutate).toHaveBeenCalledWith(event, '/api/appointments/ap1/messages', 'POST', {
			patient_id: 'p9'
		});
	});
});
