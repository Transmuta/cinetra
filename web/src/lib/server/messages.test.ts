import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => m);

// `./mutate` NÃO é dublado: o que interessa provar aqui é a escada de erros real chegando à
// tela (403 → "sem permissão"), e um duplo devolveria a mensagem que o próprio teste escreveu.
import { fetchMessages, sendConfirmation } from './messages';

const event = {} as never;

function res(status: number, body?: unknown) {
	return { ok: status >= 200 && status < 300, status, json: async () => body };
}

beforeEach(() => {
	m.apiFetch.mockReset();
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
	function corpoEnviado() {
		return JSON.parse(String(m.apiFetch.mock.calls[0][2].body));
	}

	it('sem paciente, manda corpo vazio (vale para todos os participantes)', async () => {
		m.apiFetch.mockResolvedValueOnce(res(201, { resultados: [] }));

		await sendConfirmation(event, 'ap1');

		expect(m.apiFetch.mock.calls[0][1]).toBe('/api/appointments/ap1/messages');
		expect(m.apiFetch.mock.calls[0][2].method).toBe('POST');
		expect(corpoEnviado()).toEqual({});
	});

	it('com paciente, recorta um participante', async () => {
		// Numa turma, reenviar para quem falhou não pode disparar para os outros três.
		m.apiFetch.mockResolvedValueOnce(res(201, { resultados: [] }));

		await sendConfirmation(event, 'ap1', 'p9');

		expect(corpoEnviado()).toEqual({ patient_id: 'p9' });
	});

	it('devolve o resultado POR PARTICIPANTE — o 201 sozinho não diz que saiu', async () => {
		// A API aceita o pedido e o Dispatch pode pular. Quem só olha o status responde "Feito"
		// para um envio que não aconteceu.
		m.apiFetch.mockResolvedValueOnce(
			res(201, { resultados: [{ patientId: 'p1', enviado: false, motivo: 'canal_indisponivel' }] })
		);

		const r = await sendConfirmation(event, 'ap1');

		expect(r.ok).toBe(true);
		expect(r.resultados).toEqual([
			{ patientId: 'p1', enviado: false, motivo: 'canal_indisponivel', agendadoPara: null }
		]);
	});

	it('passa adiante PARA QUANDO o envio foi adiado', async () => {
		// Aceito ≠ saiu: dentro da janela de silêncio (§7) o 201 é uma promessa com hora marcada, e
		// é essa hora que impede o toast de dizer "Mensagem enviada".
		m.apiFetch.mockResolvedValueOnce(
			res(201, {
				resultados: [{ patientId: 'p1', enviado: true, agendadoPara: '2026-08-11T11:00:00Z' }]
			})
		);

		const r = await sendConfirmation(event, 'ap1');

		expect(r.resultados[0].agendadoPara).toBe('2026-08-11T11:00:00Z');
	});

	it('corpo fora da forma esperada não vira envio inventado', async () => {
		m.apiFetch.mockResolvedValueOnce(res(201, { resultados: 'oi' }));

		expect((await sendConfirmation(event, 'ap1')).resultados).toEqual([]);
	});

	it('erro da API mantém a escada de mensagens', async () => {
		m.apiFetch.mockResolvedValueOnce(res(403));

		const r = await sendConfirmation(event, 'ap1');

		expect(r.ok).toBe(false);
		expect(r.status).toBe(403);
		expect(r.error).toMatch(/permissão/);
	});

	it('rede caída não levanta', async () => {
		m.apiFetch.mockRejectedValueOnce(new Error('offline'));

		expect(await sendConfirmation(event, 'ap1')).toMatchObject({ ok: false, status: 0 });
	});
});
