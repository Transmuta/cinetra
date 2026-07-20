import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({
	fetchAgenda: vi.fn(),
	fetchAvailability: vi.fn(),
	createAppointment: vi.fn()
}));
vi.mock('$lib/server/appointments', () => m);

import { load, actions } from './+page.server';
import { meFixture } from '$lib/testing/fixtures';
import type { Me } from '$lib/session';

type LoadOk = {
	appointments: unknown[];
	professionals: unknown[];
	appointmentTypes: unknown[];
	patients: unknown[];
	availability: unknown[];
	agora: string;
	timezone: string;
	date: string;
	today: string;
	hidden: string[];
};

// O load lê o FUSO da clínica do layout pai — é só isso que ele precisa saber antes da
// primeira busca, para resolver que dia é na clínica (achado (f)(4) do doc 26). O relógio é
// do próprio BFF, e o `today` que vai para a tela vem da resposta da API.
let parentSpy: ReturnType<typeof vi.fn>;

function ev(search = '', me: Partial<Me> = {}) {
	parentSpy = vi.fn(async () => ({ me: meFixture(me) }));
	return { url: new URL(`http://x/agenda${search}`), parent: parentSpy } as never;
}

const runLoad = async (search = '', me: Partial<Me> = {}): Promise<LoadOk> =>
	(await load(ev(search, me))) as LoadOk;

const payload = (over: Record<string, unknown> = {}) => ({
	status: 200,
	data: {
		appointments: [{ id: 'a1' }],
		professionals: [{ id: 'p1' }],
		appointment_types: [{ id: 't1' }],
		patients: [{ id: 'pat1', nome: 'Maria Silva', tel: null, ativo: true }],
		agora: '2026-07-20T14:00:00Z',
		timezone: 'America/Sao_Paulo',
		...over
	}
});

beforeEach(() => {
	Object.values(m).forEach((fn) => fn.mockReset());
	m.fetchAvailability.mockResolvedValue({
		status: 200,
		professionals: [
			{ professional_id: 'p1', days: [{ date: '2026-07-20', periods: [['08:00', '18:00']] }] }
		]
	});
});

describe('load', () => {
	it('200 → agenda, expediente e o relógio do SERVIDOR', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		const r = await runLoad('?date=2026-07-20');

		expect(r.appointments).toHaveLength(1);
		expect(r.professionals).toHaveLength(1);
		expect(r.appointmentTypes).toHaveLength(1);
		expect(r.availability).toHaveLength(1);
		// `agora` vem do servidor — a linha do agora não pode depender do relógio do browser.
		expect(r.agora).toBe('2026-07-20T14:00:00Z');
		expect(r.timezone).toBe('America/Sao_Paulo');
	});

	it('entrega o sidecar de pacientes para a tela resolver os nomes dos blocos', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		const r = await runLoad('?date=2026-07-20');
		expect(r.patients).toEqual([{ id: 'pat1', nome: 'Maria Silva', tel: null, ativo: true }]);
	});

	it('janela sem agendamento → sidecar vazio, não ausente', async () => {
		m.fetchAgenda.mockResolvedValue(payload({ appointments: [], patients: [] }));
		expect((await runLoad('?date=2026-07-20')).patients).toEqual([]);
	});

	it('a visão Dia pede UM dia (from = to)', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		await runLoad('?date=2026-07-20');

		const params = m.fetchAgenda.mock.calls[0][1];
		expect(params.from).toBe('2026-07-20');
		expect(params.to).toBe('2026-07-20');
	});

	// O doc 25 §6 quer a hachura do buraco real de CADA coluna, e isso já custou um fan-out de
	// uma requisição por profissional (achado (f) do doc 26). Hoje é UMA requisição com a lista
	// inteira. A asserção é na CONTAGEM porque é ela que regride sem quebrar nada visível.
	it('pede o expediente de todas as colunas numa requisição só', async () => {
		m.fetchAgenda.mockResolvedValue(payload({ professionals: [{ id: 'p1' }, { id: 'p2' }] }));
		await runLoad('?date=2026-07-20');

		expect(m.fetchAvailability).toHaveBeenCalledTimes(1);
		expect(m.fetchAvailability.mock.calls[0][1].professional_ids).toEqual(['p1', 'p2']);
	});

	it('sem profissional nenhum, nem chega a pedir expediente', async () => {
		m.fetchAgenda.mockResolvedValue(payload({ professionals: [] }));
		const r = await runLoad('?date=2026-07-20');

		expect(m.fetchAvailability).not.toHaveBeenCalled();
		expect(r.availability).toEqual([]);
	});

	it('cada expediente sai carimbado com a coluna a que pertence', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		const r = await runLoad('?date=2026-07-20');
		expect(r.availability[0]).toMatchObject({ professional_id: 'p1', periods: [['08:00', '18:00']] });
	});

	it('profissional sem expediente devolvido vira dia fechado, não buraco no mapa', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		m.fetchAvailability.mockResolvedValue({ status: 200, professionals: [] });
		const r = await runLoad('?date=2026-07-20');
		expect(r.availability[0]).toMatchObject({ professional_id: 'p1', periods: [] });
	});

	// A lista sai das COLUNAS, não da resposta: se a API devolver expediente de alguém que não
	// está na agenda, ele não vira coluna fantasma; e a ordem é a das colunas.
	it('a resposta é reordenada pelas colunas, e o que sobra é descartado', async () => {
		m.fetchAgenda.mockResolvedValue(payload({ professionals: [{ id: 'p1' }, { id: 'p2' }] }));
		m.fetchAvailability.mockResolvedValue({
			status: 200,
			professionals: [
				{ professional_id: 'p9', days: [{ date: '2026-07-20', periods: [['07:00', '08:00']] }] },
				{ professional_id: 'p2', days: [{ date: '2026-07-20', periods: [['09:00', '10:00']] }] }
			]
		});

		const r = await runLoad('?date=2026-07-20');

		expect(r.availability).toHaveLength(2);
		expect(r.availability[0]).toMatchObject({ professional_id: 'p1', periods: [] });
		expect(r.availability[1]).toMatchObject({
			professional_id: 'p2',
			periods: [['09:00', '10:00']]
		});
	});

	it('`?date=` inválido cai no hoje da clínica em vez de estourar', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		const r = await runLoad('?date=ontem');
		expect(r.date).toBe(r.today);
	});

	it('`?profs=` lista os profissionais ocultos', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		const r = await runLoad('?date=2026-07-20&profs=p1,p2');
		expect(r.hidden).toEqual(['p1', 'p2']);
	});

	it('sem `?profs=`, ninguém está oculto', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		expect((await runLoad('?date=2026-07-20')).hidden).toEqual([]);
	});

	// O "hoje" é o da CLÍNICA. Às 22h de São Paulo o UTC já virou o dia seguinte; abrir a
	// agenda sem `?date=` tem que mostrar o dia que a recepção chama de hoje, não o de amanhã.
	//
	// Antes isto custava DUAS buscas: o load chutava o dia em UTC, descobria o fuso na resposta
	// e refazia tudo. Hoje o FUSO vem do /me e o relógio é o do próprio BFF, então o dia certo é
	// sabido antes da primeira chamada — a asserção da contagem impede o round-trip extra de
	// voltar (achado (f)(4)).
	it('sem `?date=`, acerta o dia da clínica na PRIMEIRA busca', async () => {
		// 01:00Z de 21/07 → em São Paulo ainda é 20/07.
		vi.setSystemTime(new Date('2026-07-21T01:00:00Z'));
		m.fetchAgenda.mockResolvedValue(payload({ agora: '2026-07-21T01:00:00Z' }));

		const r = await runLoad('');

		expect(r.today).toBe('2026-07-20');
		expect(r.date).toBe('2026-07-20');
		expect(m.fetchAgenda).toHaveBeenCalledTimes(1);
		expect(m.fetchAgenda.mock.calls[0][1].from).toBe('2026-07-20');
		vi.useRealTimers();
	});

	it('em horário comercial também é uma busca só', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		await runLoad('');
		expect(m.fetchAgenda).toHaveBeenCalledTimes(1);
	});

	// Fuso ausente no /me não pode derrubar a agenda: degrada para UTC, que é o comportamento
	// anterior a esta mudança — pior dia mostrado na janela noturna, nunca tela de erro.
	it('sem fuso no /me, cai em UTC em vez de estourar', async () => {
		m.fetchAgenda.mockResolvedValue(payload({ agora: '2026-07-21T01:00:00Z', timezone: 'UTC' }));
		vi.setSystemTime(new Date('2026-07-21T01:00:00Z'));
		const r = await runLoad('', { timezone: null });
		expect(r.today).toBe('2026-07-21');
		vi.useRealTimers();
	});

	// P2 do bate-volta: `await event.parent()` põe o load do layout e o da página EM FILA.
	// Quando a data é explícita — que é a navegação do dia a dia, cada clique nas setas — o
	// fuso não é pré-requisito de nada, e bloquear nele custava um round-trip inteiro (~+40ms,
	// 44%) em toda carga. Sem `?date=` a fila é legítima: é o fuso que decide QUE dia buscar.
	it('com `?date=` explícito, não bloqueia no layout', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		await runLoad('?date=2026-08-15');
		expect(parentSpy).not.toHaveBeenCalled();
	});

	it('sem `?date=`, aí sim espera o layout — é dele que vem o fuso', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		await runLoad('');
		expect(parentSpy).toHaveBeenCalledTimes(1);
	});

	// O `today` da tela sai do relógio da API na resposta, NÃO do /me. O `me` é carregado pelo
	// layout, que o SvelteKit não reexecuta em navegação client-side (`goto`) — então um `agora`
	// vindo dali congela no instante em que a aba abriu, e uma aba aberta atravessando a
	// meia-noite passaria a apontar "Hoje" para ontem. Exatamente a classe de bug que a janela
	// noturna já custou uma vez.
	it('o `today` acompanha o relógio da API, não o do layout', async () => {
		m.fetchAgenda.mockResolvedValue(payload({ agora: '2026-07-25T14:00:00Z' }));
		const r = await runLoad('?date=2026-07-25');
		expect(r.today).toBe('2026-07-25');
	});

	it('`?date=` explícito é respeitado mesmo diferindo de hoje', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		const r = await runLoad('?date=2026-08-15');
		expect(r.date).toBe('2026-08-15');
		expect(m.fetchAgenda).toHaveBeenCalledTimes(1);
	});

	it('erro da API vira erro de rota', async () => {
		m.fetchAgenda.mockResolvedValue({ status: 502, data: null });
		await expect(runLoad('?date=2026-07-20')).rejects.toBeTruthy();
	});
});

// -------------------------------------------------------------------------------------

function formEvent(fields: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

const validos = {
	starts_at: '2026-07-20T11:00:00.000Z',
	professional_id: 'p1',
	appointment_type_id: 't1',
	patient_ids: '["pat1"]'
};

describe('action criar', () => {
	it('caminho feliz → ok', async () => {
		m.createAppointment.mockResolvedValueOnce({ ok: true, status: 201 });
		const r = await actions.criar(formEvent(validos));
		expect(r).toEqual({ ok: true, action: 'criar' });
	});

	it('repassa o corpo do contrato', async () => {
		m.createAppointment.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.criar(formEvent({ ...validos, encaixe: 'on', obs: 'trazer exame' }));

		const input = m.createAppointment.mock.calls[0][1];
		expect(input).toMatchObject({
			starts_at: '2026-07-20T11:00:00.000Z',
			professional_id: 'p1',
			appointment_type_id: 't1',
			patient_ids: ['pat1'],
			encaixe: true,
			obs: 'trazer exame'
		});
	});

	it('sem encaixe marcado, o flag vai falso', async () => {
		m.createAppointment.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.criar(formEvent(validos));
		expect(m.createAppointment.mock.calls[0][1].encaixe).toBe(false);
	});

	it('paciente é obrigatório e nem chega à API', async () => {
		const r = (await actions.criar(formEvent({ ...validos, patient_ids: '[]' }))) as {
			data: { error: string };
		};
		expect(r.data.error).toBe('Escolha ao menos um paciente.');
		expect(m.createAppointment).not.toHaveBeenCalled();
	});

	it('patient_ids ilegível não derruba a action', async () => {
		const r = (await actions.criar(formEvent({ ...validos, patient_ids: 'nada disso' }))) as {
			data: { error: string };
		};
		expect(r.data.error).toBe('Escolha ao menos um paciente.');
	});

	it('horário inválido é recusado antes da API', async () => {
		const r = (await actions.criar(formEvent({ ...validos, starts_at: 'amanhã cedo' }))) as {
			data: { error: string };
		};
		expect(r.data.error).toBe('Escolha uma data e um horário válidos.');
		expect(m.createAppointment).not.toHaveBeenCalled();
	});

	it('profissional e tipo são obrigatórios', async () => {
		const semProf = (await actions.criar(
			formEvent({ ...validos, professional_id: '' })
		)) as { data: { error: string } };
		expect(semProf.data.error).toBe('Escolha o profissional e o tipo de atendimento.');
	});

	// O motivo de toda a mudança no `mutate`: a tela precisa do `code` para oferecer a saída.
	it('conflito devolve `code` para a UI poder oferecer o Encaixe', async () => {
		m.createAppointment.mockResolvedValueOnce({
			ok: false,
			status: 422,
			code: 'schedule_conflict',
			error: 'Esse horário sobrepõe outro agendamento.',
			details: [{ field: null, message: 'Esse horário sobrepõe outro agendamento.' }]
		});

		const r = (await actions.criar(formEvent(validos))) as {
			status: number;
			data: { code: string; error: string };
		};
		expect(r.status).toBe(422);
		expect(r.data.code).toBe('schedule_conflict');
		expect(r.data.error).toBe('Esse horário sobrepõe outro agendamento.');
	});

	it('fora do expediente também chega com código', async () => {
		m.createAppointment.mockResolvedValueOnce({
			ok: false,
			status: 422,
			code: 'outside_business_hours',
			error: 'Fora do expediente.'
		});
		const r = (await actions.criar(formEvent(validos))) as { data: { code: string } };
		expect(r.data.code).toBe('outside_business_hours');
	});

	it('duração customizada (A-D8) viaja quando informada', async () => {
		m.createAppointment.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.criar(formEvent({ ...validos, duration_minutos: '80' }));
		expect(m.createAppointment.mock.calls[0][1].duration_minutos).toBe(80);
	});

	it('duração vazia ou absurda não viaja', async () => {
		m.createAppointment.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.criar(formEvent({ ...validos, duration_minutos: '0' }));
		expect(m.createAppointment.mock.calls[0][1]).not.toHaveProperty('duration_minutos');
	});

	it('obs vazia não vira string vazia no corpo', async () => {
		m.createAppointment.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.criar(formEvent({ ...validos, obs: '   ' }));
		expect(m.createAppointment.mock.calls[0][1]).not.toHaveProperty('obs');
	});
});
