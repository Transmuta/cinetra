import { describe, it, expect } from 'vitest';
import {
	STATUS_META,
	STATUS_ORDER,
	m2t,
	t2m,
	zonedParts,
	toUtcIso,
	todayInZone,
	shiftDate,
	dayLabel,
	started,
	needsAction,
	conflictIds,
	canCreateAppointment,
	canCreateEncaixe,
	gridRange,
	closedIntervals,
	toInterval,
	parseDateParam,
	parseHiddenProfs,
	serializeHiddenProfs,
	patientNameMap,
	type Appointment
} from './agenda';

const SP = 'America/Sao_Paulo';

function appt(over: Partial<Appointment> = {}): Appointment {
	return {
		id: 'a1',
		starts_at: '2026-07-20T11:00:00Z',
		ends_at: '2026-07-20T11:50:00Z',
		status: 'agendado',
		encaixe: false,
		obs: null,
		professional_id: 'p1',
		appointment_type_id: 't1',
		package_id: null,
		version: 1,
		created_by_id: null,
		patient_ids: ['pat1'],
		...over
	};
}

describe('STATUS_META', () => {
	it('cobre os seis status com os rótulos do protótipo (:810)', () => {
		expect(STATUS_ORDER).toHaveLength(6);
		expect(STATUS_ORDER.map((s) => STATUS_META[s].label)).toEqual([
			'Agendado',
			'Confirmado',
			'Em atendimento',
			'Concluído',
			'Faltou',
			'Cancelado'
		]);
	});

	it('concluído esmaece, cancelado risca, em atendimento pulsa', () => {
		expect(STATUS_META.concluido.dim).toBe(true);
		expect(STATUS_META.cancelado.strike).toBe(true);
		expect(STATUS_META.em_atendimento.live).toBe(true);
	});

	it('agendado e cancelado não pintam o fundo (tone nulo)', () => {
		expect(STATUS_META.agendado.tone).toBeNull();
		expect(STATUS_META.cancelado.tone).toBeNull();
	});
});

describe('m2t / t2m', () => {
	it('converte minuto do dia em HH:MM com zero à esquerda', () => {
		expect(m2t(0)).toBe('00:00');
		expect(m2t(480)).toBe('08:00');
		expect(m2t(702)).toBe('11:42');
		expect(m2t(1439)).toBe('23:59');
	});

	it('t2m é o inverso', () => {
		for (const t of ['00:00', '08:00', '11:42', '23:59']) expect(m2t(t2m(t))).toBe(t);
	});

	it('t2m tolera lixo devolvendo 0 em vez de NaN', () => {
		expect(t2m('')).toBe(0);
		expect(t2m('abc')).toBe(0);
	});
});

describe('fuso — a ponte entre instante absoluto e relógio de parede da clínica', () => {
	// starts_at chega em UTC; a grade é desenhada no horário LOCAL da clínica. Usar
	// getHours() do browser leria o fuso do CONTAINER (UTC) e desenharia 3h fora do lugar.
	it('lê o horário da clínica, não o do processo', () => {
		expect(zonedParts('2026-07-20T11:00:00Z', SP)).toEqual({ date: '2026-07-20', minutes: 480 });
	});

	it('instante que cruza a meia-noite cai no dia local certo', () => {
		expect(zonedParts('2026-07-21T02:00:00Z', SP)).toEqual({ date: '2026-07-20', minutes: 1380 });
	});

	it('toUtcIso é o caminho de volta', () => {
		expect(toUtcIso('2026-07-20', '08:00', SP)).toBe('2026-07-20T11:00:00.000Z');
	});

	it('ida e volta preserva o relógio de parede', () => {
		for (const t of ['08:00', '12:30', '18:45']) {
			expect(zonedParts(toUtcIso('2026-07-20', t, SP), SP).minutes).toBe(t2m(t));
		}
	});

	// O Brasil não tem DST desde 2019, então com America/Sao_Paulo estes ramos NUNCA rodam —
	// o teste passaria vazio. America/Santiago tem as duas transições (doc 25 §4).
	describe('DST (America/Santiago)', () => {
		const CL = 'America/Santiago';

		it('horário normal converte pelo offset do dia', () => {
			expect(toUtcIso('2026-07-20', '09:00', CL)).toBe('2026-07-20T13:00:00.000Z');
		});

		// Adiantamento: 00:00 → 01:00 em 06/09/2026. 00:30 não existe.
		it('horário INEXISTENTE (gap) é empurrado para depois do salto', () => {
			const iso = toUtcIso('2026-09-06', '00:30', CL);
			expect(iso).toBe('2026-09-06T04:30:00.000Z');
			// Não pode cair ANTES do salto (23:30 do dia anterior) — seria voltar no tempo.
			expect(zonedParts(iso, CL).date).toBe('2026-09-06');
		});

		// Atraso: 23:30 de 04/04/2026 acontece duas vezes. Política: a primeira.
		it('horário AMBÍGUO resolve na primeira ocorrência', () => {
			expect(toUtcIso('2026-04-04', '23:30', CL)).toBe('2026-04-05T02:30:00.000Z');
		});
	});
});

describe('todayInZone / shiftDate / dayLabel', () => {
	it('"hoje" é o dia da CLÍNICA no instante do servidor', () => {
		// 02:00Z de 21/07 ainda é 20/07 em São Paulo.
		expect(todayInZone('2026-07-21T02:00:00Z', SP)).toBe('2026-07-20');
	});

	it('shiftDate anda dias sem cair em armadilha de fuso', () => {
		expect(shiftDate('2026-07-20', 1)).toBe('2026-07-21');
		expect(shiftDate('2026-07-20', -1)).toBe('2026-07-19');
		expect(shiftDate('2026-07-31', 1)).toBe('2026-08-01');
		expect(shiftDate('2026-01-01', -1)).toBe('2025-12-31');
	});

	it('rótulo contextual em português', () => {
		expect(dayLabel('2026-06-25', '2026-01-01')).toBe('quinta-feira, 25 de junho');
	});

	it('quando a data é hoje, ganha o sufixo " · hoje"', () => {
		expect(dayLabel('2026-06-25', '2026-06-25')).toBe('quinta-feira, 25 de junho · hoje');
	});
});

// RN-58: são DUAS fronteiras diferentes, e confundi-las é o bug clássico do port.
describe('started × needsAction — duas fronteiras distintas', () => {
	const agora = '2026-07-20T11:30:00Z'; // sessão 11:00–11:50: começou, não terminou

	it('"já começou" olha o INÍCIO', () => {
		expect(started(appt(), agora)).toBe(true);
	});

	it('"precisa de ação" olha o FIM — ainda não terminou, então não', () => {
		expect(needsAction(appt(), agora)).toBe(false);
	});

	it('depois do fim, e ainda agendado, precisa de ação', () => {
		expect(needsAction(appt(), '2026-07-20T12:00:00Z')).toBe(true);
	});

	it('confirmado também precisa de ação depois do fim', () => {
		expect(needsAction(appt({ status: 'confirmado' }), '2026-07-20T12:00:00Z')).toBe(true);
	});

	it('já resolvido (concluído/faltou/cancelado) nunca precisa de ação', () => {
		for (const status of ['concluido', 'faltou', 'cancelado'] as const) {
			expect(needsAction(appt({ status }), '2026-07-20T12:00:00Z')).toBe(false);
		}
	});

	it('em atendimento não precisa de ação (alguém já está cuidando)', () => {
		expect(needsAction(appt({ status: 'em_atendimento' }), '2026-07-20T12:00:00Z')).toBe(false);
	});

	it('antes da hora, nenhuma das duas', () => {
		const antes = '2026-07-20T09:00:00Z';
		expect(started(appt(), antes)).toBe(false);
		expect(needsAction(appt(), antes)).toBe(false);
	});

	it('exatamente no instante de início já conta como começado', () => {
		expect(started(appt(), '2026-07-20T11:00:00Z')).toBe(true);
	});
});

describe('conflictIds — o conflito é EXIBIDO mesmo quando não bloqueia (A-D2 opção b)', () => {
	const a = appt({ id: 'a', starts_at: '2026-07-20T11:00:00Z', ends_at: '2026-07-20T12:00:00Z' });

	it('sobreposição no mesmo profissional acusa os dois', () => {
		const b = appt({ id: 'b', starts_at: '2026-07-20T11:30:00Z', ends_at: '2026-07-20T12:30:00Z' });
		expect(conflictIds([a, b])).toEqual(new Set(['a', 'b']));
	});

	it('profissionais diferentes nunca conflitam', () => {
		const b = appt({
			id: 'b',
			professional_id: 'p2',
			starts_at: '2026-07-20T11:30:00Z',
			ends_at: '2026-07-20T12:30:00Z'
		});
		expect(conflictIds([a, b]).size).toBe(0);
	});

	it('encostar fim-com-início não é conflito', () => {
		const b = appt({ id: 'b', starts_at: '2026-07-20T12:00:00Z', ends_at: '2026-07-20T13:00:00Z' });
		expect(conflictIds([a, b]).size).toBe(0);
	});

	it('cancelado não conflita, nos dois sentidos', () => {
		const b = appt({
			id: 'b',
			status: 'cancelado',
			starts_at: '2026-07-20T11:30:00Z',
			ends_at: '2026-07-20T12:30:00Z'
		});
		expect(conflictIds([a, b]).size).toBe(0);
	});

	// A divergência DELIBERADA do protótipo (:830/:835), decidida em A-D2(b): lá o encaixe
	// some do cálculo e a recepção perde de vista justamente o que motivou o encaixe.
	it('ENCAIXE continua sendo exibido como conflito (não some da tela)', () => {
		const b = appt({
			id: 'b',
			encaixe: true,
			starts_at: '2026-07-20T11:30:00Z',
			ends_at: '2026-07-20T12:30:00Z'
		});
		expect(conflictIds([a, b])).toEqual(new Set(['a', 'b']));
	});

	it('agenda sem sobreposição não acusa nada', () => {
		expect(conflictIds([a]).size).toBe(0);
		expect(conflictIds([]).size).toBe(0);
	});
});

describe('permissões (espelho de UX; a autoridade é a policy da API)', () => {
	it('os quatro papéis criam agendamento (A8)', () => {
		for (const p of ['owner', 'admin', 'recepcao', 'profissional'] as const) {
			expect(canCreateAppointment(p)).toBe(true);
		}
		expect(canCreateAppointment(null)).toBe(false);
	});

	it('encaixe é só de owner/admin/recepção (A9) — profissional não', () => {
		expect(canCreateEncaixe('owner')).toBe(true);
		expect(canCreateEncaixe('admin')).toBe(true);
		expect(canCreateEncaixe('recepcao')).toBe(true);
		expect(canCreateEncaixe('profissional')).toBe(false);
		expect(canCreateEncaixe(undefined)).toBe(false);
	});
});

describe('gridRange — a faixa vertical é DERIVADA do expediente (A12), não 08–18 fixo', () => {
	it('sem expediente e sem agendamento, cai no padrão 08–18', () => {
		expect(gridRange([], [])).toEqual({ start: 480, end: 1080 });
	});

	it('deriva do expediente das colunas', () => {
		const range = gridRange(
			[
				[
					[420, 720],
					[780, 1140]
				]
			],
			[]
		);
		expect(range).toEqual({ start: 420, end: 1140 });
	});

	it('usa o expediente MAIS LARGO entre as colunas', () => {
		const range = gridRange(
			[
				[[480, 720]],
				[[540, 1200]]
			],
			[]
		);
		expect(range).toEqual({ start: 480, end: 1200 });
	});

	// Sem isto, um encaixe às 07:00 combinado por telefone ficaria FORA da área desenhada —
	// invisível, e ninguém descobre que ele existe.
	it('ESTENDE a faixa para conter agendamento fora do expediente', () => {
		const range = gridRange([[[480, 1080]]], [{ start: 400, end: 450 }]);
		expect(range.start).toBeLessThanOrEqual(400);

		const tarde = gridRange([[[480, 1080]]], [{ start: 1100, end: 1160 }]);
		expect(tarde.end).toBeGreaterThanOrEqual(1160);
	});

	it('arredonda para a hora cheia (as linhas do grid são horárias)', () => {
		const range = gridRange([[[430, 1130]]], []);
		expect(range.start % 60).toBe(0);
		expect(range.end % 60).toBe(0);
		expect(range.start).toBeLessThanOrEqual(430);
		expect(range.end).toBeGreaterThanOrEqual(1130);
	});

	it('nunca devolve faixa invertida ou vazia', () => {
		const range = gridRange([[]], []);
		expect(range.end).toBeGreaterThan(range.start);
	});
});

describe('closedIntervals — o que hachurar em cada coluna', () => {
	const range = { start: 480, end: 1080 };

	it('o buraco REAL entre períodos (o almoço de verdade, não 12–13 cravado)', () => {
		expect(
			closedIntervals(
				[
					[480, 720],
					[780, 1080]
				],
				range
			)
		).toEqual([[720, 780]]);
	});

	// GAP-05: no protótipo o almoço era 12:00–13:00 hardcoded e decorativo, igual em todas as
	// colunas. Aqui cada coluna mostra o SEU buraco — e ficarem diferentes é o correto.
	it('almoço deslocado hachura no lugar certo, não em 12–13', () => {
		expect(
			closedIntervals(
				[
					[480, 690],
					[750, 1080]
				],
				range
			)
		).toEqual([[690, 750]]);
	});

	it('expediente que começa tarde e termina cedo hachura as duas pontas', () => {
		expect(closedIntervals([[600, 900]], range)).toEqual([
			[480, 600],
			[900, 1080]
		]);
	});

	it('dia fechado hachura a faixa inteira', () => {
		expect(closedIntervals([], range)).toEqual([[480, 1080]]);
	});

	it('expediente cobrindo a faixa toda não hachura nada', () => {
		expect(closedIntervals([[480, 1080]], range)).toEqual([]);
	});

	it('períodos fora de ordem ou que extrapolam a faixa são normalizados', () => {
		expect(
			closedIntervals(
				[
					[780, 1200],
					[300, 720]
				],
				range
			)
		).toEqual([[720, 780]]);
	});
});

describe('toInterval — agendamento vira retângulo na grade do dia exibido', () => {
	it('converte para minutos locais', () => {
		expect(toInterval(appt(), SP)).toEqual({ id: 'a1', start: 480, end: 530 });
	});

	it('agendamento que atravessa a meia-noite é aparado no fim do dia', () => {
		const a = appt({ starts_at: '2026-07-21T02:00:00Z', ends_at: '2026-07-21T04:00:00Z' });
		const iv = toInterval(a, SP);
		expect(iv.start).toBe(1380);
		expect(iv.end).toBeLessThanOrEqual(1440);
	});

	it('bloco de duração zero ainda recebe altura mínima de 1 minuto', () => {
		const a = appt({ ends_at: '2026-07-20T11:00:00Z' });
		expect(toInterval(a, SP).end).toBeGreaterThan(toInterval(a, SP).start);
	});
});

// O sidecar `patients` de GET /api/appointments (id, nome, tel, ativo): só os pacientes
// CITADOS na janela, não o cadastro inteiro.
describe('patientNameMap — resolve o nome do bloco', () => {
	const pacientes = [
		{ id: 'pat1', nome: 'Maria Silva', tel: '11999990000', ativo: true },
		{ id: 'pat2', nome: 'João Souza', tel: null, ativo: true }
	];

	it('indexa por id', () => {
		expect(patientNameMap(pacientes)).toEqual({ pat1: 'Maria Silva', pat2: 'João Souza' });
	});

	it('janela sem agendamento devolve mapa vazio', () => {
		expect(patientNameMap([])).toEqual({});
	});

	// A regra que o backend pediu EXPLICITAMENTE, e que é o bug #2 de novo: quem tem sessão
	// marcada precisa de nome no bloco mesmo estando arquivado. Filtrar por `ativo` aqui
	// deixaria o bloco anônimo justamente no caso que a recepção precisa entender.
	it('paciente ARQUIVADO continua tendo nome — não se filtra por `ativo`', () => {
		const mapa = patientNameMap([
			{ id: 'pat9', nome: 'Ana Arquivada', tel: null, ativo: false }
		]);
		expect(mapa.pat9).toBe('Ana Arquivada');
	});

	it('tolera o sidecar ausente sem estourar', () => {
		expect(patientNameMap(undefined)).toEqual({});
	});
});

describe('estado na URL', () => {
	it('data válida passa; inválida cai no fallback', () => {
		expect(parseDateParam('2026-07-20', '2026-01-01')).toBe('2026-07-20');
		expect(parseDateParam(null, '2026-01-01')).toBe('2026-01-01');
		expect(parseDateParam('ontem', '2026-01-01')).toBe('2026-01-01');
		expect(parseDateParam('2026-13-45', '2026-01-01')).toBe('2026-01-01');
	});

	it('profissionais ocultos viajam por vírgula', () => {
		expect(parseHiddenProfs('p1,p2')).toEqual(['p1', 'p2']);
		expect(parseHiddenProfs(null)).toEqual([]);
		expect(parseHiddenProfs('')).toEqual([]);
		expect(parseHiddenProfs('p1, ,p2,')).toEqual(['p1', 'p2']);
	});

	it('serialize é o inverso e some da URL quando vazio', () => {
		expect(serializeHiddenProfs(['p1', 'p2'])).toBe('p1,p2');
		expect(serializeHiddenProfs([])).toBeNull();
	});
});
