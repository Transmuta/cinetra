import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({
	fetchAgenda: vi.fn(),
	fetchAvailability: vi.fn(),
	fetchCounts: vi.fn(),
	createAppointment: vi.fn(),
	transitionParticipant: vi.fn()
}));
vi.mock('$lib/server/appointments', () => m);

// AN-12 (doc 64): a conversão da fila disparada de DENTRO do drawer (a vaga que abriu).
const w = vi.hoisted(() => ({ convertEntry: vi.fn() }));
vi.mock('$lib/server/waitlist', () => w);

const msg = vi.hoisted(() => ({ sendConfirmation: vi.fn() }));
vi.mock('$lib/server/messages', () => msg);

import { load, actions } from './+page.server';
import { meFixture, dayCountFixture } from '$lib/testing/fixtures';
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
let dependsSpy: ReturnType<typeof vi.fn>;

function ev(search = '', me: Partial<Me> = {}) {
	parentSpy = vi.fn(async () => ({ me: meFixture(me) }));
	dependsSpy = vi.fn();
	return {
		url: new URL(`http://x/agenda${search}`),
		parent: parentSpy,
		depends: dependsSpy
	} as never;
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
		// O fallback de data inválida usa o relógio do BFF (`new Date()`); o `today` da tela usa o
		// `agora` da API. Em produção são o mesmo instante do mesmo servidor; aqui o `agora` é fixo
		// no fixture (2026-07-20), então cravamos o relógio do BFF no mesmo dia — senão o teste
		// depende da data de parede e quebra ao virar a meia-noite.
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-20T14:00:00Z'));
		try {
			m.fetchAgenda.mockResolvedValue(payload());
			const r = await runLoad('?date=ontem');
			expect(r.date).toBe(r.today);
			expect(r.date).toBe('2026-07-20');
		} finally {
			vi.useRealTimers();
		}
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

	// A etiqueta é o que liga o tempo real (Entrega 3) à recarga: sem ela, `invalidate` não
	// acha este load e Semana/Mês nunca atualizariam — em silêncio, porque o socket continuaria
	// entregando eventos que ninguém consegue aplicar.
	it('registra a etiqueta de invalidação do tempo real', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		await runLoad('?date=2026-07-20');
		expect(dependsSpy).toHaveBeenCalledWith('agenda:dados');
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
// Visões (Entrega 2). Dia e Lista leem BLOCOS; Semana e Mês leem CONTAGENS — mês não carrega
// bloco nenhum (doc 25 §10), que é o que separa uma barrinha de 31 dias de payload.
// -------------------------------------------------------------------------------------

type ViewLoad = LoadOk & { view: string; days?: unknown[] };

const runView = async (search: string): Promise<ViewLoad> => (await load(ev(search))) as ViewLoad;

const countsPayload = (days: unknown[], professionals: unknown[] = [{ id: 'p1' }]) => ({
	status: 200,
	data: { days, professionals, agora: '2026-07-20T14:00:00Z', timezone: 'America/Sao_Paulo' }
});

const dia = (date: string) => dayCountFixture(date, [{ total: 1, ocupado_minutos: 50 }]);

describe('load — visões', () => {
	it('`?view=` inválido cai na visão Dia', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		expect((await runView('?date=2026-07-20&view=semanal')).view).toBe('dia');
	});

	it('Lista lê os blocos do dia — é outro render dos mesmos dados (B-D1)', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		const r = await runView('?date=2026-07-20&view=lista');

		expect(r.view).toBe('lista');
		expect(r.appointments).toHaveLength(1);
		expect(m.fetchCounts).not.toHaveBeenCalled();
	});

	// A hachura é geometria do grid; a Lista não tem grid. Pedir expediente ali é um
	// round-trip que nada consome.
	it('Lista não pede expediente', async () => {
		m.fetchAgenda.mockResolvedValue(payload());
		await runView('?date=2026-07-20&view=lista');
		expect(m.fetchAvailability).not.toHaveBeenCalled();
	});

	it('Semana pede a janela de segunda a domingo, e nenhum bloco', async () => {
		m.fetchCounts.mockResolvedValue(countsPayload([dia('2026-07-20')]));
		const r = await runView('?date=2026-07-22&view=semana');

		expect(m.fetchCounts.mock.calls[0][1]).toEqual({ from: '2026-07-20', to: '2026-07-26' });
		expect(m.fetchAgenda).not.toHaveBeenCalled();
		expect(r.days).toHaveLength(1);
	});

	// A grade do mês tem até 42 células, e o teto do servidor é 31 dias — pedir a grade
	// inteira é 422 garantido em todo mês que ocupa 6 linhas. Pede-se o MÊS; as células de
	// fora ficam sem contagem, que é como o protótipo já as pintava (opacidade .5).
	it('Mês pede o mês, não a grade de 42 dias', async () => {
		m.fetchCounts.mockResolvedValue(countsPayload([dia('2026-07-01')]));
		await runView('?date=2026-07-15&view=mes');

		expect(m.fetchCounts.mock.calls[0][1]).toEqual({ from: '2026-07-01', to: '2026-07-31' });
	});

	it('Mês respeita a duração real do mês', async () => {
		m.fetchCounts.mockResolvedValue(countsPayload([]));
		await runView('?date=2026-02-10&view=mes');
		expect(m.fetchCounts.mock.calls[0][1]).toEqual({ from: '2026-02-01', to: '2026-02-28' });
	});

	it('nas contagens, o `today` também sai do relógio da resposta', async () => {
		m.fetchCounts.mockResolvedValue(countsPayload([]));
		const r = await runView('?date=2026-07-22&view=semana');
		expect(r.today).toBe('2026-07-20');
		expect(r.timezone).toBe('America/Sao_Paulo');
	});

	it('erro nas contagens vira erro de rota, não semana vazia', async () => {
		m.fetchCounts.mockResolvedValue({ status: 502, data: null });
		await expect(runView('?date=2026-07-22&view=semana')).rejects.toBeTruthy();
	});

	// A barra lateral é a mesma nas quatro visões, e é dela que sai o filtro de ocultar. Sem os
	// profissionais aqui ela abre vazia — e o toggle fica inoperante justamente em Semana e Mês.
	// Pego na verificação ao vivo; nenhum teste apontava para isso.
	it('as visões de contagem também trazem os profissionais da barra lateral', async () => {
		m.fetchCounts.mockResolvedValue(countsPayload([dia('2026-07-20')], [{ id: 'p1' }, { id: 'p2' }]));
		const r = await runView('?date=2026-07-22&view=semana');
		expect(r.professionals).toHaveLength(2);
	});

	it('o filtro de profissionais ocultos atravessa as visões', async () => {
		m.fetchCounts.mockResolvedValue(countsPayload([dia('2026-07-20')]));
		const r = await runView('?date=2026-07-22&view=semana&profs=p2,p3');
		expect(r.hidden).toEqual(['p2', 'p3']);
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

// Presença por participante (A2, doc 41): uma action para os quatro verbos. O que ela precisa
// travar é o roteamento — id do bloco, id do paciente, verbo e a versão do BLOCO (o guard de 409).
describe('action presenca', () => {
	it('repassa bloco, participante, verbo e a versão do bloco', async () => {
		m.transitionParticipant.mockResolvedValueOnce({ ok: true, status: 200 });

		const r = await actions.presenca(
			formEvent({ id: 'a1', patient_id: 'pac1', kind: 'no_show', expected_version: '7' })
		);

		expect(r).toEqual({ ok: true, action: 'presenca' });
		const [, id, patientId, kind, input] = m.transitionParticipant.mock.calls[0];
		expect([id, patientId, kind]).toEqual(['a1', 'pac1', 'no_show']);
		expect(input).toEqual({ expected_version: 7 });
	});

	it('justify leva a flag; os outros verbos não a mandam', async () => {
		m.transitionParticipant.mockResolvedValueOnce({ ok: true, status: 200 });

		await actions.presenca(
			formEvent({
				id: 'a1',
				patient_id: 'pac1',
				kind: 'justify',
				justificada: 'true',
				expected_version: '7'
			})
		);

		expect(m.transitionParticipant.mock.calls[0][4]).toEqual({
			expected_version: 7,
			justificada: true
		});
	});

	// O `kind` decide o SEGMENTO da URL: aceitá-lo cru deixaria o cliente escolher o caminho.
	it('verbo fora da lista → 400 sem tocar a API', async () => {
		const r = await actions.presenca(
			formEvent({ id: 'a1', patient_id: 'pac1', kind: '../../cancel', expected_version: '1' })
		);

		expect(r).toMatchObject({ status: 400 });
		expect(m.transitionParticipant).not.toHaveBeenCalled();
	});

	it('sem participante → 400', async () => {
		const r = await actions.presenca(formEvent({ id: 'a1', kind: 'complete' }));
		expect(r).toMatchObject({ status: 400 });
		expect(m.transitionParticipant).not.toHaveBeenCalled();
	});

	it('409 do servidor sobe com o code (o drawer manda recarregar)', async () => {
		m.transitionParticipant.mockResolvedValueOnce({
			ok: false,
			status: 409,
			error: 'Recarregue',
			code: 'version_conflict'
		});

		const r = await actions.presenca(
			formEvent({ id: 'a1', patient_id: 'pac1', kind: 'complete', expected_version: '1' })
		);

		expect(r).toMatchObject({ status: 409 });
	});
});

// AN-12 (doc 64): agendar um candidato da fila NA vaga que abriu — a conversão (`convert`)
// disparada do drawer, com o slot do próprio bloco (não escolhido pelo usuário).
describe('action agendar_fila', () => {
	const slot = {
		id: 'e1',
		starts_at: '2026-07-20T11:00:00Z',
		professional_id: 'p1',
		appointment_type_id: 't1',
		duration_minutos: '50'
	};

	beforeEach(() => {
		w.convertEntry.mockReset();
		w.convertEntry.mockResolvedValue({ ok: true, status: 201 });
	});

	it('caminho feliz → converte com o corpo do contrato', async () => {
		const r = await actions.agendar_fila(formEvent(slot));

		expect(r).toEqual({ ok: true, action: 'agendar_fila' });
		expect(w.convertEntry.mock.calls[0][1]).toBe('e1');
		expect(w.convertEntry.mock.calls[0][2]).toMatchObject({
			starts_at: '2026-07-20T11:00:00Z',
			professional_id: 'p1',
			appointment_type_id: 't1',
			encaixe: false,
			duration_minutos: 50
		});
	});

	// A falta ocupa o horário para a exclusion constraint (`status <> 'cancelado'`), então a
	// conversão numa vaga de falta só entra como encaixe — o flag viaja do drawer.
	it('encaixe marcado viaja true', async () => {
		await actions.agendar_fila(formEvent({ ...slot, encaixe: 'true' }));
		expect(w.convertEntry.mock.calls[0][2].encaixe).toBe(true);
	});

	it('sem o item da fila → 400 e nem chega à API', async () => {
		const r = await actions.agendar_fila(formEvent({ ...slot, id: '' }));
		expect(r).toMatchObject({ status: 400 });
		expect(w.convertEntry).not.toHaveBeenCalled();
	});

	it('slot sem horário válido → 400', async () => {
		const r = await actions.agendar_fila(formEvent({ ...slot, starts_at: 'agora há pouco' }));
		expect(r).toMatchObject({ status: 400 });
		expect(w.convertEntry).not.toHaveBeenCalled();
	});

	it('slot sem profissional ou tipo → 400', async () => {
		const r = await actions.agendar_fila(formEvent({ ...slot, appointment_type_id: '' }));
		expect(r).toMatchObject({ status: 400 });
		expect(w.convertEntry).not.toHaveBeenCalled();
	});

	it('duração inválida é omitida (a API usa a do tipo)', async () => {
		await actions.agendar_fila(formEvent({ ...slot, duration_minutos: '0' }));
		expect(w.convertEntry.mock.calls[0][2]).not.toHaveProperty('duration_minutos');
	});

	// O horário foi tomado no meio-tempo (vaga de cancelamento re-ocupada): o `code` sobe para a
	// tela oferecer a saída de encaixe — mesmo desenho do criar/remarcar.
	it('schedule_conflict sobe com o code', async () => {
		w.convertEntry.mockResolvedValueOnce({
			ok: false,
			status: 422,
			error: 'Esse horário sobrepõe outro agendamento.',
			code: 'schedule_conflict'
		});

		const r = (await actions.agendar_fila(formEvent(slot))) as {
			status: number;
			data: { code: string };
		};

		expect(r.status).toBe(422);
		expect(r.data.code).toBe('schedule_conflict');
	});
});

// Doc 52 §6: o disparo manual da confirmação. A API responde 201 **com o resultado por
// participante**, e o pecado que estes testes prendem é tratar o status como resposta — a
// recepção clicava em "Enviar agora", lia "Feito" e nada tinha saído.
describe('action confirmar', () => {
	beforeEach(() => {
		msg.sendConfirmation.mockReset();
	});

	it('enviou para todos → sucesso, com a mensagem do envio', async () => {
		msg.sendConfirmation.mockResolvedValueOnce({
			ok: true,
			status: 201,
			resultados: [{ patientId: 'pat1', enviado: true, motivo: null }]
		});

		const r = await actions.confirmar(formEvent({ id: 'a1' }));

		expect(r).toEqual({ ok: true, action: 'confirmar', mensagem: 'Mensagem enviada' });
	});

	it('201 sem NINGUÉM enviado NÃO é sucesso — e a mensagem diz o motivo certo', async () => {
		// O cenário do balcão: paciente com celular na ficha e o canal desligado. Enquanto isto
		// virava "Feito", a recepção supunha que a mensagem tinha saído.
		msg.sendConfirmation.mockResolvedValueOnce({
			ok: true,
			status: 201,
			resultados: [{ patientId: 'pat1', enviado: false, motivo: 'canal_indisponivel' }]
		});

		const r = (await actions.confirmar(formEvent({ id: 'a1' }))) as {
			status: number;
			data: { error: string };
		};

		expect(r.status).toBe(422);
		expect(r.data.error).toMatch(/WhatsApp/);
		// E não manda a recepção corrigir uma ficha que já está certa.
		expect(r.data.error).not.toMatch(/cadastrado/);
	});

	it('na turma, o parcial conta quantos ficaram de fora', async () => {
		msg.sendConfirmation.mockResolvedValueOnce({
			ok: true,
			status: 201,
			resultados: [
				{ patientId: 'pat1', enviado: true, motivo: null },
				{ patientId: 'pat2', enviado: false, motivo: 'opt_out' }
			]
		});

		const r = (await actions.confirmar(formEvent({ id: 'a1' }))) as {
			ok: boolean;
			mensagem: string;
		};

		expect(r.ok).toBe(true);
		expect(r.mensagem).toMatch(/1 de 2/);
	});

	it('com patient_id, recorta o participante', async () => {
		msg.sendConfirmation.mockResolvedValueOnce({ ok: true, status: 201, resultados: [] });

		await actions.confirmar(formEvent({ id: 'a1', patient_id: 'pat9' }));

		expect(msg.sendConfirmation.mock.calls[0][2]).toBe('pat9');
	});

	it('erro da API sobe como erro', async () => {
		msg.sendConfirmation.mockResolvedValueOnce({
			ok: false,
			status: 403,
			error: 'Você não tem permissão para esta ação.',
			resultados: []
		});

		const r = (await actions.confirmar(formEvent({ id: 'a1' }))) as { status: number };

		expect(r.status).toBe(403);
	});
});
