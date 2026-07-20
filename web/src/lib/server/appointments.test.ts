import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => m);

import {
	fetchAgenda,
	fetchAvailability,
	createAppointment,
	agendaQuery,
	availabilityQuery
} from './appointments';

function res(status: number, body?: unknown): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		json: async () => {
			if (body === undefined) throw new SyntaxError('não é JSON');
			return body;
		}
	} as unknown as Response;
}

const event = {} as never;

const payload = {
	appointments: [{ id: 'a1' }],
	professionals: [{ id: 'p1' }],
	appointment_types: [{ id: 't1' }],
	patients: [{ id: 'pat1', nome: 'Maria Silva', tel: '11999990000', ativo: true }],
	agora: '2026-07-20T14:00:00Z',
	timezone: 'America/Sao_Paulo'
};

beforeEach(() => m.apiFetch.mockReset());

describe('agendaQuery', () => {
	it('monta from/to', () => {
		expect(agendaQuery({ from: '2026-07-20', to: '2026-07-20' })).toBe(
			'?from=2026-07-20&to=2026-07-20'
		);
	});

	it('`to` ausente vira o próprio `from` (a visão Dia é um dia só)', () => {
		expect(agendaQuery({ from: '2026-07-20' })).toBe('?from=2026-07-20&to=2026-07-20');
	});

	it('professional_id entra quando informado', () => {
		expect(agendaQuery({ from: '2026-07-20', professional_id: 'p1' })).toContain(
			'professional_id=p1'
		);
	});

	it('escapa o que vem do cliente', () => {
		expect(agendaQuery({ from: '2026-07-20', professional_id: 'a&b=c' })).toContain(
			'professional_id=a%26b%3Dc'
		);
	});
});

describe('availabilityQuery', () => {
	it('monta os três parâmetros', () => {
		expect(
			availabilityQuery({
				professional_ids: ['p1'],
				date_from: '2026-07-20',
				date_to: '2026-07-20'
			})
		).toBe('?professional_id=p1&date_from=2026-07-20&date_to=2026-07-20');
	});

	// O que mata o fan-out: a lista inteira de colunas numa requisição só (achado (f) do
	// doc 26). Sem esta asserção, uma regressão que voltasse a mandar um id por vez passaria
	// verde — o resultado na tela é o mesmo, só que com N vezes mais leituras no banco.
	it('vários profissionais viram UM parâmetro separado por vírgula', () => {
		expect(
			availabilityQuery({
				professional_ids: ['p1', 'p2', 'p3'],
				date_from: '2026-07-20',
				date_to: '2026-07-20'
			})
		).toBe('?professional_id=p1%2Cp2%2Cp3&date_from=2026-07-20&date_to=2026-07-20');
	});

	it('sem profissional nenhum, pede o expediente de todos', () => {
		expect(availabilityQuery({ date_from: '2026-07-20', date_to: '2026-07-20' })).toBe(
			'?date_from=2026-07-20&date_to=2026-07-20'
		);
	});
});

describe('fetchAgenda', () => {
	it('200 → devolve o payload inteiro, inclusive `agora` e `timezone`', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, payload));
		const r = await fetchAgenda(event, { from: '2026-07-20' });
		expect(r.status).toBe(200);
		expect(r.data?.agora).toBe('2026-07-20T14:00:00Z');
		expect(r.data?.timezone).toBe('America/Sao_Paulo');
		expect(r.data?.appointments).toHaveLength(1);
	});

	it('traz o sidecar `patients` — os citados na janela, ao lado de professionals/types', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, payload));
		const r = await fetchAgenda(event, { from: '2026-07-20' });
		expect(r.data?.patients).toEqual([
			{ id: 'pat1', nome: 'Maria Silva', tel: '11999990000', ativo: true }
		]);
	});

	it('erro da API → data nula com o status preservado', async () => {
		m.apiFetch.mockResolvedValueOnce(res(403));
		expect(await fetchAgenda(event, { from: '2026-07-20' })).toEqual({ status: 403, data: null });
	});

	it('falha de rede → status 0, sem estourar', async () => {
		m.apiFetch.mockRejectedValueOnce(new Error('boom'));
		expect(await fetchAgenda(event, { from: '2026-07-20' })).toEqual({ status: 0, data: null });
	});
});

describe('fetchAvailability', () => {
	it('200 → um item por profissional, com seus dias', async () => {
		m.apiFetch.mockResolvedValueOnce(
			res(200, {
				professionals: [
					{ professional_id: 'p1', days: [{ date: '2026-07-20', periods: [['08:00', '12:00']] }] },
					{ professional_id: 'p2', days: [{ date: '2026-07-20', periods: [] }] }
				]
			})
		);
		const r = await fetchAvailability(event, {
			professional_ids: ['p1', 'p2'],
			date_from: '2026-07-20',
			date_to: '2026-07-20'
		});
		expect(r.professionals).toHaveLength(2);
		expect(r.professionals[0].professional_id).toBe('p1');
		expect(r.professionals[0].days[0].periods[0]).toEqual(['08:00', '12:00']);
	});

	// O expediente é ENFEITE da grade (hachura). Se ele falhar, a agenda ainda tem que
	// abrir com os agendamentos — degradar é melhor que a tela inteira em erro.
	it('erro vira lista vazia, não exceção — a agenda abre mesmo assim', async () => {
		m.apiFetch.mockResolvedValueOnce(res(500));
		expect(await fetchAvailability(event, { date_from: 'x', date_to: 'x' })).toEqual({
			status: 500,
			professionals: []
		});
	});

	it('falha de rede também degrada para vazio', async () => {
		m.apiFetch.mockRejectedValueOnce(new Error('boom'));
		expect(
			(await fetchAvailability(event, { date_from: 'x', date_to: 'x' })).professionals
		).toEqual([]);
	});
});

describe('createAppointment', () => {
	it('201 → ok', async () => {
		m.apiFetch.mockResolvedValueOnce(res(201, { appointment: { id: 'a9' } }));
		const r = await createAppointment(event, {
			starts_at: '2026-07-20T11:00:00Z',
			professional_id: 'p1',
			appointment_type_id: 't1',
			patient_ids: ['pat1']
		});
		expect(r.ok).toBe(true);
	});

	it('manda exatamente o corpo do contrato (sem ends_at, sem clinic_id)', async () => {
		m.apiFetch.mockResolvedValueOnce(res(201, { appointment: { id: 'a9' } }));
		await createAppointment(event, {
			starts_at: '2026-07-20T11:00:00Z',
			professional_id: 'p1',
			appointment_type_id: 't1',
			patient_ids: ['pat1'],
			encaixe: true,
			obs: 'trazer exame'
		});

		const [, path, init] = m.apiFetch.mock.calls[0];
		expect(path).toBe('/api/appointments');
		expect(init.method).toBe('POST');
		const body = JSON.parse(init.body);
		// `ends_at` é DERIVADO no servidor (A3) — mandá-lo seria inventar autoridade.
		expect(body).not.toHaveProperty('ends_at');
		expect(body).not.toHaveProperty('clinic_id');
		expect(body.encaixe).toBe(true);
		expect(body.obs).toBe('trazer exame');
	});

	// É por este caminho que a UI descobre que pode oferecer "marcar como Encaixe".
	it('422 schedule_conflict chega com code e details intactos', async () => {
		m.apiFetch.mockResolvedValueOnce(
			res(422, {
				error: 'invalid',
				code: 'schedule_conflict',
				details: [{ field: null, message: 'Esse horário sobrepõe outro agendamento.' }]
			})
		);
		const r = await createAppointment(event, {
			starts_at: '2026-07-20T11:00:00Z',
			professional_id: 'p1',
			appointment_type_id: 't1',
			patient_ids: ['pat1']
		});
		expect(r.ok).toBe(false);
		expect(r.code).toBe('schedule_conflict');
		expect(r.error).toBe('Esse horário sobrepõe outro agendamento.');
	});
});
