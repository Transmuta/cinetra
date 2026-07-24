import { describe, it, expect, vi, beforeEach } from 'vitest';

const wl = vi.hoisted(() => ({
	fetchWaitlist: vi.fn(),
	enqueueEntry: vi.fn(),
	updateEntry: vi.fn(),
	dequeueEntry: vi.fn(),
	offerSlot: vi.fn(),
	convertEntry: vi.fn()
}));
vi.mock('$lib/server/waitlist', () => wl);
const at = vi.hoisted(() => ({ fetchAppointmentTypes: vi.fn() }));
vi.mock('$lib/server/appointment-types', () => at);

import { load, actions } from './+page.server';
import { meFixture } from '$lib/testing/fixtures';
import type { Me } from '$lib/session';

function ev(search = '', me: Partial<Me> = {}) {
	return {
		url: new URL(`http://x/fila${search}`),
		parent: vi.fn(async () => ({ me: meFixture(me) })),
		depends: vi.fn()
	} as never;
}

const okWaitlist = {
	status: 200,
	data: {
		waitlist: [{ id: 'e1' }],
		professionals: [{ id: 'p1' }],
		today: '2026-07-21',
		page: { limit: 50, offset: 0, total: 1, more: false },
		counts: { todas: 1, urgente: 0, alta: 0, normal: 1, baixa: 0 }
	}
};

beforeEach(() => {
	Object.values(wl).forEach((fn) => fn.mockReset());
	at.fetchAppointmentTypes.mockReset();
	at.fetchAppointmentTypes.mockResolvedValue({
		status: 200,
		data: { appointment_types: [{ id: 't1', ativo: true }], cap_turma_padrao: 4 }
	});
});

describe('load', () => {
	it('200 → fila, diretório, tipos e o fuso do /me', async () => {
		wl.fetchWaitlist.mockResolvedValueOnce(okWaitlist);
		const r = (await load(ev())) as {
			waitlist: unknown[];
			professionals: unknown[];
			appointmentTypes: unknown[];
			timezone: string;
			prio: string;
		};

		expect(r.waitlist).toHaveLength(1);
		expect(r.professionals).toHaveLength(1);
		expect(r.appointmentTypes).toHaveLength(1);
		expect(r.timezone).toBe('America/Sao_Paulo');
		expect(r.prio).toBe('todas');
	});

	it('repassa `today` (data local) para a lista marcar regra expirada', async () => {
		wl.fetchWaitlist.mockResolvedValueOnce(okWaitlist);
		const r = (await load(ev())) as { today: string };
		expect(r.today).toBe('2026-07-21');
	});

	it('lê o segmento `?prio=` e o MANDA para a API (filtro no servidor, F6)', async () => {
		wl.fetchWaitlist.mockResolvedValueOnce(okWaitlist);
		const r = (await load(ev('?prio=urgente'))) as { prio: string };

		expect(r.prio).toBe('urgente');
		expect(wl.fetchWaitlist.mock.calls[0][1]).toEqual({ limit: 50, offset: 0, prio: 'urgente' });
	});

	// F6: `?page=` vira `offset` para a API — a mesma tradução da lista de Pacientes.
	it('`?page=3` vira offset na chamada e volta como `current`', async () => {
		wl.fetchWaitlist.mockResolvedValueOnce(okWaitlist);
		const r = (await load(ev('?page=3'))) as { current: number; pageInfo: unknown };

		expect(wl.fetchWaitlist.mock.calls[0][1]).toEqual({ limit: 50, offset: 100, prio: 'todas' });
		expect(r.current).toBe(3);
		expect(r.pageInfo).toEqual({ limit: 50, offset: 0, total: 1, more: false });
	});

	it('`?page=` inválido não vira offset negativo', async () => {
		wl.fetchWaitlist.mockResolvedValueOnce(okWaitlist);
		const r = (await load(ev('?page=-2'))) as { current: number };

		expect(wl.fetchWaitlist.mock.calls[0][1]).toEqual({ limit: 50, offset: 0, prio: 'todas' });
		expect(r.current).toBe(1);
	});

	it('as contagens da sidebar vêm do servidor (não da página)', async () => {
		wl.fetchWaitlist.mockResolvedValueOnce(okWaitlist);
		const r = (await load(ev())) as { counts: { todas: number } };
		expect(r.counts.todas).toBe(1);
	});

	it('`?prio=` desconhecido cai em "todas"', async () => {
		wl.fetchWaitlist.mockResolvedValueOnce(okWaitlist);
		const r = (await load(ev('?prio=lixo'))) as { prio: string };
		expect(r.prio).toBe('todas');
	});

	it('sem fuso no /me, cai em UTC (não derruba a tela)', async () => {
		wl.fetchWaitlist.mockResolvedValueOnce(okWaitlist);
		const r = (await load(ev('', { timezone: null }))) as { timezone: string };
		expect(r.timezone).toBe('UTC');
	});

	it('tipos indisponíveis → lista vazia, a fila ainda abre', async () => {
		wl.fetchWaitlist.mockResolvedValueOnce(okWaitlist);
		at.fetchAppointmentTypes.mockResolvedValueOnce({ status: 502, data: null });
		const r = (await load(ev())) as { appointmentTypes: unknown[] };
		expect(r.appointmentTypes).toEqual([]);
	});

	it('fila indisponível → error de gateway', async () => {
		wl.fetchWaitlist.mockResolvedValueOnce({ status: 502, data: null });
		await expect(load(ev())).rejects.toMatchObject({ status: 502 });
	});
});

function formEvent(fields: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

describe('action enqueue', () => {
	it('caminho feliz → ok', async () => {
		wl.enqueueEntry.mockResolvedValueOnce({ ok: true, status: 201 });
		const r = await actions.enqueue(formEvent({ patient_id: 'pat1', prio: 'alta', janela: 'manha' }));
		expect(r).toEqual({ ok: true, action: 'enqueue' });
	});

	it('paciente é obrigatório e nem chega à API', async () => {
		const r = (await actions.enqueue(formEvent({ prio: 'alta' }))) as { data: { error: string } };
		expect(r.data.error).toBe('Escolha um paciente.');
		expect(wl.enqueueEntry).not.toHaveBeenCalled();
	});

	it('parseia professional_ids e rules dos campos JSON, e normaliza a regra', async () => {
		wl.enqueueEntry.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.enqueue(
			formEvent({
				patient_id: 'pat1',
				prio: 'urgente',
				janela: 'tarde',
				professional_ids: '["p1","p2"]',
				rules: JSON.stringify([{ tipo: 'semana', dows: [1, 3], data: null, periodos: [['09:00', '11:00']] }])
			})
		);
		const input = wl.enqueueEntry.mock.calls[0][1];
		expect(input.professional_ids).toEqual(['p1', 'p2']);
		expect(input.prio).toBe('urgente');
		expect(input.janela).toBe('tarde');
		expect(input.rules[0]).toEqual({
			tipo: 'semana',
			dows: [1, 3],
			data: null,
			periodos: [['09:00', '11:00']]
		});
	});

	it('prioridade/janela forjadas caem no default', async () => {
		wl.enqueueEntry.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.enqueue(formEvent({ patient_id: 'pat1', prio: 'super', janela: 'noite' }));
		const input = wl.enqueueEntry.mock.calls[0][1];
		expect(input.prio).toBe('normal');
		expect(input.janela).toBe('qualquer');
	});

	it('JSON ilegível em rules/ids não derruba a action (vira vazio)', async () => {
		wl.enqueueEntry.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.enqueue(formEvent({ patient_id: 'pat1', professional_ids: 'nada', rules: '{{' }));
		const input = wl.enqueueEntry.mock.calls[0][1];
		expect(input.professional_ids).toEqual([]);
		expect(input.rules).toEqual([]);
	});

	it('obs vazia não vira string vazia no corpo do create', async () => {
		wl.enqueueEntry.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.enqueue(formEvent({ patient_id: 'pat1', obs: '   ' }));
		expect(wl.enqueueEntry.mock.calls[0][1]).not.toHaveProperty('obs');
	});
});

describe('action atualizar', () => {
	it('manda o conjunto de campos, inclusive obs vazio (limpa)', async () => {
		wl.updateEntry.mockResolvedValueOnce({ ok: true, status: 200 });
		await actions.atualizar(formEvent({ id: 'e1', prio: 'baixa', janela: 'manha', obs: '' }));
		const [, id, input] = wl.updateEntry.mock.calls[0];
		expect(id).toBe('e1');
		expect(input).toMatchObject({ prio: 'baixa', janela: 'manha', obs: '' });
	});

	it('sem id → 400 sem tocar a API', async () => {
		const r = (await actions.atualizar(formEvent({ prio: 'alta' }))) as { data: { error: string } };
		expect(r.data.error).toBe('Item da fila não informado.');
		expect(wl.updateEntry).not.toHaveBeenCalled();
	});
});

describe('action remover', () => {
	it('chama dequeue com o id', async () => {
		wl.dequeueEntry.mockResolvedValueOnce({ ok: true, status: 204 });
		const r = await actions.remover(formEvent({ id: 'e1' }));
		expect(wl.dequeueEntry).toHaveBeenCalledWith(expect.anything(), 'e1');
		expect(r).toEqual({ ok: true, action: 'remover' });
	});

	it('404 da API propaga como falha', async () => {
		wl.dequeueEntry.mockResolvedValueOnce({ ok: false, status: 404, error: 'Registro não encontrado.' });
		const r = (await actions.remover(formEvent({ id: 'e1' }))) as { status: number };
		expect(r.status).toBe(404);
	});
});

describe('action converter', () => {
	const validos = {
		id: 'e1',
		starts_at: '2026-07-21T12:00:00.000Z',
		professional_id: 'p1',
		appointment_type_id: 't1'
	};

	it('caminho feliz → ok', async () => {
		wl.convertEntry.mockResolvedValueOnce({ ok: true, status: 201 });
		const r = await actions.converter(formEvent(validos));
		expect(r).toEqual({ ok: true, action: 'converter' });
	});

	it('horário inválido é recusado antes da API', async () => {
		const r = (await actions.converter(formEvent({ ...validos, starts_at: 'amanhã' }))) as {
			data: { error: string };
		};
		expect(r.data.error).toBe('Escolha uma data e um horário válidos.');
		expect(wl.convertEntry).not.toHaveBeenCalled();
	});

	it('profissional e tipo são obrigatórios', async () => {
		const r = (await actions.converter(formEvent({ ...validos, appointment_type_id: '' }))) as {
			data: { error: string };
		};
		expect(r.data.error).toBe('Escolha o profissional e o tipo de atendimento.');
	});

	it('encaixe e duração customizada viajam quando informados', async () => {
		wl.convertEntry.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.converter(formEvent({ ...validos, encaixe: 'on', duration_minutos: '80' }));
		const input = wl.convertEntry.mock.calls[0][2];
		expect(input.encaixe).toBe(true);
		expect(input.duration_minutos).toBe(80);
	});

	// A conversão herda o schedule_conflict do agendamento: o `code` chega para a tela oferecer
	// a saída (Encaixe), como no modal de criar da agenda.
	it('schedule_conflict devolve code para a UI oferecer o Encaixe', async () => {
		wl.convertEntry.mockResolvedValueOnce({
			ok: false,
			status: 422,
			code: 'schedule_conflict',
			error: 'Esse horário sobrepõe outro agendamento.'
		});
		const r = (await actions.converter(formEvent(validos))) as {
			status: number;
			data: { code: string };
		};
		expect(r.status).toBe(422);
		expect(r.data.code).toBe('schedule_conflict');
	});
});
