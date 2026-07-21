import { describe, it, expect, vi, beforeEach } from 'vitest';

const api = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => api);
const mut = vi.hoisted(() => ({ mutate: vi.fn() }));
vi.mock('./mutate', () => mut);

import {
	fetchWaitlist,
	fetchSlots,
	enqueueEntry,
	updateEntry,
	dequeueEntry,
	offerSlot,
	convertEntry
} from './waitlist';

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

beforeEach(() => {
	api.apiFetch.mockReset();
	mut.mutate.mockReset();
	mut.mutate.mockResolvedValue({ ok: true, status: 201 });
});

describe('fetchWaitlist', () => {
	it('200 → a fila e os profissionais da barra', async () => {
		api.apiFetch.mockResolvedValueOnce(
			res(200, { waitlist: [{ id: 'e1' }], professionals: [{ id: 'p1' }] })
		);
		const r = await fetchWaitlist(event);
		expect(r.status).toBe(200);
		expect(r.data?.waitlist).toHaveLength(1);
		expect(r.data?.professionals).toHaveLength(1);
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/waitlist');
	});

	it('erro da API → data nula com o status preservado', async () => {
		api.apiFetch.mockResolvedValueOnce(res(403));
		expect(await fetchWaitlist(event)).toEqual({ status: 403, data: null });
	});

	it('falha de rede → status 0, sem estourar', async () => {
		api.apiFetch.mockRejectedValueOnce(new Error('boom'));
		expect(await fetchWaitlist(event)).toEqual({ status: 0, data: null });
	});
});

describe('fetchSlots', () => {
	it('200 → as vagas do item, com o id escapado no caminho', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { slots: [{ date: '2026-07-21', start: 540 }] }));
		const r = await fetchSlots(event, 'e1');
		expect(r.data?.slots).toHaveLength(1);
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/waitlist/e1/slots');
	});

	it('id perigoso é escapado (não escapa do recurso)', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { slots: [] }));
		await fetchSlots(event, '../appointments');
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/waitlist/..%2Fappointments/slots');
	});

	it('erro vira data null (o modal mostra o vazio, não estoura)', async () => {
		api.apiFetch.mockResolvedValueOnce(res(404));
		expect((await fetchSlots(event, 'e1')).data).toBeNull();
	});

	it('falha de rede também degrada para null', async () => {
		api.apiFetch.mockRejectedValueOnce(new Error('boom'));
		expect(await fetchSlots(event, 'e1')).toEqual({ status: 0, data: null });
	});
});

describe('escrita — delega ao mutate no verbo/rota certos', () => {
	it('enqueueEntry: POST /api/waitlist com o corpo do contrato', async () => {
		await enqueueEntry(event, {
			patient_id: 'pat1',
			prio: 'alta',
			janela: 'manha',
			professional_ids: ['p1'],
			rules: [{ tipo: 'semana', dows: [1], data: null, periodos: [['09:00', '11:00']] }]
		});
		const [, path, method, body] = mut.mutate.mock.calls[0];
		expect(path).toBe('/api/waitlist');
		expect(method).toBe('POST');
		expect(body).toMatchObject({ patient_id: 'pat1', prio: 'alta', janela: 'manha' });
		expect(body.rules[0].tipo).toBe('semana');
	});

	it('updateEntry: PATCH /api/waitlist/:id (id escapado)', async () => {
		await updateEntry(event, 'e1', { prio: 'urgente' });
		const [, path, method, body] = mut.mutate.mock.calls[0];
		expect(path).toBe('/api/waitlist/e1');
		expect(method).toBe('PATCH');
		expect(body).toEqual({ prio: 'urgente' });
	});

	it('dequeueEntry: DELETE /api/waitlist/:id sem corpo', async () => {
		await dequeueEntry(event, 'e1');
		const [, path, method, body] = mut.mutate.mock.calls[0];
		expect(path).toBe('/api/waitlist/e1');
		expect(method).toBe('DELETE');
		expect(body).toBeUndefined();
	});

	it('offerSlot: POST /api/waitlist/:id/offer', async () => {
		await offerSlot(event, 'e1', { professional_id: 'p1', starts_at: '2026-07-21T12:00:00.000Z' });
		const [, path, method] = mut.mutate.mock.calls[0];
		expect(path).toBe('/api/waitlist/e1/offer');
		expect(method).toBe('POST');
	});

	// A corrida da oferta: outra recepção já segurou o horário → 409 slot_held com quem segura.
	it('offerSlot propaga o 409 slot_held (code + mensagem intactos)', async () => {
		mut.mutate.mockResolvedValueOnce({
			ok: false,
			status: 409,
			code: 'slot_held',
			error: 'Ana está oferecendo este horário.'
		});
		const r = await offerSlot(event, 'e1', {
			professional_id: 'p1',
			starts_at: '2026-07-21T12:00:00.000Z'
		});
		expect(r.ok).toBe(false);
		expect(r.status).toBe(409);
		expect(r.code).toBe('slot_held');
		expect(r.error).toBe('Ana está oferecendo este horário.');
	});

	it('convertEntry: POST /api/waitlist/:id/convert com o corpo do agendamento', async () => {
		await convertEntry(event, 'e1', {
			starts_at: '2026-07-21T12:00:00.000Z',
			professional_id: 'p1',
			appointment_type_id: 't1'
		});
		const [, path, method, body] = mut.mutate.mock.calls[0];
		expect(path).toBe('/api/waitlist/e1/convert');
		expect(method).toBe('POST');
		expect(body).toMatchObject({ professional_id: 'p1', appointment_type_id: 't1' });
	});

	// O horário foi tomado no meio-tempo → o 422 schedule_conflict volta pela conversão.
	it('convertEntry propaga o schedule_conflict do agendamento', async () => {
		mut.mutate.mockResolvedValueOnce({
			ok: false,
			status: 422,
			code: 'schedule_conflict',
			error: 'Esse horário sobrepõe outro agendamento.'
		});
		const r = await convertEntry(event, 'e1', {
			starts_at: '2026-07-21T12:00:00.000Z',
			professional_id: 'p1',
			appointment_type_id: 't1'
		});
		expect(r.code).toBe('schedule_conflict');
	});
});
