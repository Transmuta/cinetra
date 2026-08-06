import { describe, it, expect } from 'vitest';
import {
	STATUS_META,
	STATUS_ORDER,
	m2t,
	timeToMinutes,
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
	canMutateAppointment,
	isTerminal,
	canExcludeAppointment,
	statusActions,
	gridRange,
	closedIntervals,
	toInterval,
	parseDateParam,
	parseHiddenProfs,
	serializeHiddenProfs,
	appointmentLink,
	appointmentHref,
	patientNameMap,
	participantActions,
	resolvedCount,
	packageBadge,
	packageDebit,
	replyBadges,
	shortDayLabel,
	presetDoBotao,
	type Appointment,
	type Participant
} from './agenda';
import type { Period } from './scheduling';

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
		version: 1,
		created_by_id: null,
		cancel_reason: null,
		reschedule_reason: null,
		veio_da_fila: false,
		dias_na_fila: null,
		patient_ids: ['pat1'],
		participants: [],
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

	// Cada status tem a SUA cor. `agendado` e `cancelado` viviam os dois com `tone: null` — que a
	// tela resolvia como `muted` —, então dois estados opostos ("ainda vai acontecer" e "não vai
	// mais") saíam pintados igual no ponto do cartão, na legenda e no chip do drawer. O protótipo
	// já os separava (`statusMeta` :810: `muted` para agendado, `faint` para cancelado).
	it('cada status tem cor própria — nenhuma repetida', () => {
		const tons = STATUS_ORDER.map((s) => STATUS_META[s].tone);
		expect(tons).toEqual(['muted', 'info', 'accent', 'success', 'danger', 'faint']);
		expect(new Set(tons).size).toBe(STATUS_ORDER.length);
	});

	// Ninguém mais precisa traduzir "sem tom" para uma cor na hora de desenhar: o tom É o token.
	it('nenhum status fica sem tom', () => {
		for (const s of STATUS_ORDER) expect(STATUS_META[s].tone).toBeTruthy();
	});
});

describe('m2t', () => {
	it('converte minuto do dia em HH:MM com zero à esquerda', () => {
		expect(m2t(0)).toBe('00:00');
		expect(m2t(480)).toBe('08:00');
		expect(m2t(702)).toBe('11:42');
		expect(m2t(1439)).toBe('23:59');
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
			expect(zonedParts(toUtcIso('2026-07-20', t, SP), SP).minutes).toBe(timeToMinutes(t));
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

	// A versão curta é do drawer, onde a data é contexto e não título — no celular o painel cobre
	// o cabeçalho da agenda, que é onde o dia estava.
	it('shortDayLabel é curto e sem ponto de abreviação', () => {
		expect(shortDayLabel('2026-06-25', '2026-01-01')).toBe('qui, 25/06');
	});

	it('shortDayLabel troca a data por "hoje" quando é o dia corrente', () => {
		expect(shortDayLabel('2026-06-25', '2026-06-25')).toBe('hoje');
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
	it('agendar é do balcão (A8) — o profissional não', () => {
		for (const p of ['owner', 'admin', 'recepcao'] as const) {
			expect(canCreateAppointment(p)).toBe(true);
		}
		// 2026-08-04: o profissional passou a só VER a própria agenda. Espelho da policy do
		// `Appointment` — a autoridade continua sendo o 403 da API, isto só some com o botão.
		expect(canCreateAppointment('profissional')).toBe(false);
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
		expect(toInterval(appt(), SP)).toEqual({ id: 'a1', start: 480, end: 530, ghost: false });
	});

	// A ponte entre a regra (`ocupaGrade`) e a geometria (`layoutAppts`, que não conhece
	// status). Sem este campo o cancelado alargava a coluna sozinho.
	it('marca o cancelado como fantasma: desenha, mas não disputa raia', () => {
		expect(toInterval(appt({ status: 'cancelado' }), SP).ghost).toBe(true);
		expect(toInterval(appt({ status: 'faltou' }), SP).ghost).toBe(false);
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

	// O link que viaja NÃO leva `date`: quem recebe pode abri-lo depois de o bloco ser remarcado,
	// e a data congelada o levaria a um dia sem o bloco. Sem ela, o servidor resolve o dia pelo
	// próprio bloco. Esta asserção é o contrato — se `date` voltar para cá, o link volta a
	// quebrar em silêncio.
	it('o link do agendamento é só o id, sem data', () => {
		expect(appointmentLink('https://app.cinetra.com.br', 'a1')).toBe(
			'https://app.cinetra.com.br/agenda?agendamento=a1'
		);
		expect(appointmentLink('https://x', 'a1')).not.toContain('date=');
	});

	it('escapa o id no link', () => {
		expect(appointmentLink('https://x', 'a&b=c')).toBe('https://x/agenda?agendamento=a%26b%3Dc');
	});

	// O link INTERNO (sino, trilha, ficha) leva as duas metades: a data é o degrau de queda pela
	// regra "`date` na URL manda" — bloco fora da janela ainda abre o dia de que o aviso falava,
	// em vez de cair no hoje da clínica sem relação com o que se clicou.
	it('o link interno leva dia E id', () => {
		expect(appointmentHref('a1', '2026-07-20')).toBe('/agenda?date=2026-07-20&agendamento=a1');
	});

	it('cada metade que falta simplesmente sai do link', () => {
		expect(appointmentHref('a1', null)).toBe('/agenda?agendamento=a1');
		expect(appointmentHref(null, '2026-07-20')).toBe('/agenda?date=2026-07-20');
		expect(appointmentHref(undefined, undefined)).toBe('/agenda');
	});
});

// ---------------------------------------------------------------------------
// ACHADO 2: "HH:MM → minutos" existia em três cópias com bordas DIFERENTES —
// `timeToMinutes` (scheduling.ts) devolvia NaN, `t2m` (agenda.ts) devolvia 0, e `toMin`
// embrulhava o segundo. `0` é meia-noite, um valor VÁLIDO: lixo virava 00:00 em silêncio e
// posicionava bloco no topo da grade sem nunca lançar erro. Fonte única, borda = NaN.
// ---------------------------------------------------------------------------
describe('timeToMinutes — fonte única de HH:MM → minutos', () => {
	it('converte o horário do relógio em minuto do dia', () => {
		expect(timeToMinutes('00:00')).toBe(0);
		expect(timeToMinutes('08:00')).toBe(480);
		expect(timeToMinutes('10:07')).toBe(607);
		expect(timeToMinutes('23:59')).toBe(1439);
	});

	it('entrada inválida devolve NaN, e NÃO 0 (que é meia-noite de verdade)', () => {
		for (const lixo of ['', 'abc', '8:0:0', '99:99', '12', null, undefined]) {
			expect(Number.isNaN(timeToMinutes(lixo as string))).toBe(true);
		}
	});

	it('é o inverso de m2t', () => {
		for (const t of ['00:00', '08:00', '11:42', '23:59']) expect(m2t(timeToMinutes(t))).toBe(t);
	});

	// A geometria da grade tem que ENGOLIR o NaN em vez de propagar: expediente ilegível cai
	// no fallback, e não numa faixa de altura NaN que apaga a agenda inteira.
	it('período ilegível não contamina a faixa vertical da grade', () => {
		expect(gridRange([[['xx:xx', '18:00']]], [])).toEqual({ start: 480, end: 1080 });
	});
});

describe('ciclo de vida (Entrega 4)', () => {
	function appt(over: Partial<Appointment> = {}): Appointment {
		return {
			id: 'a1',
			starts_at: '2026-07-20T11:00:00Z',
			ends_at: '2026-07-20T11:50:00Z',
			status: 'agendado',
			encaixe: false,
			obs: null,
			cancel_reason: null,
		reschedule_reason: null,
		veio_da_fila: false,
		dias_na_fila: null,
			professional_id: 'p1',
			appointment_type_id: 't1',
			version: 1,
			created_by_id: null,
			patient_ids: ['pac1'],
			participants: [],
			...over
		};
	}

	it('isTerminal reconhece concluído/faltou/cancelado', () => {
		expect(isTerminal('agendado')).toBe(false);
		expect(isTerminal('confirmado')).toBe(false);
		expect(isTerminal('concluido')).toBe(true);
		expect(isTerminal('faltou')).toBe(true);
		expect(isTerminal('cancelado')).toBe(true);
	});

	// Mexer no ciclo de vida (remarcar, status, presença) é a mesma lista de quem agenda — e por
	// isso o profissional também saiu daqui em 2026-08-04. É o predicado que fecha o rodapé
	// inteiro do drawer, não só o botão de criar.
	it('canMutateAppointment = quem agenda, e o profissional não agenda', () => {
		expect(canMutateAppointment('recepcao')).toBe(true);
		expect(canMutateAppointment('profissional')).toBe(false);
		expect(canMutateAppointment(null)).toBe(false);
	});

	it('canExcludeAppointment: só o que não aconteceu (espelho do StatusIn do servidor)', () => {
		// Some para excluir: agendado, confirmado e cancelado.
		expect(canExcludeAppointment('agendado')).toBe(true);
		expect(canExcludeAppointment('confirmado')).toBe(true);
		expect(canExcludeAppointment('cancelado')).toBe(true);
		// Aconteceu (ou está acontecendo) → não some do drawer: reabrir antes.
		expect(canExcludeAppointment('em_atendimento')).toBe(false);
		expect(canExcludeAppointment('concluido')).toBe(false);
		expect(canExcludeAppointment('faltou')).toBe(false);
	});



	// A2 (doc 41): do trio do protótipo sobra o cancelar — concluir e faltar viraram presença.
	it('statusActions devolve só o cancelar, e ele nunca é bloqueado por horário', () => {
		const acoes = statusActions(appt(), '2026-07-20T09:00:00Z');
		expect(acoes.map((a) => a.kind)).toEqual(['cancelar']);
		expect(acoes[0].disabled).toBe(false);
	});

	// A2 (doc 41): a presença é de cada participante, e o desfecho do bloco é rollup disso. As
	// regras aqui são espelho de UX de `transition_participant/6` — o servidor é a autoridade.
	describe('participantActions', () => {
		const previsto: Participant = {
			patient_id: 'pac1',
			status: 'prevista',
			falta_justificada: false, motivo: null,
			package_id: null,
			package: null,
			resposta: null
		};

		it('antes de a sessão começar, presente/faltou ficam desabilitados com o title', () => {
			const acoes = participantActions(previsto, appt(), '2026-07-20T09:00:00Z');
			expect(acoes.map((a) => a.kind)).toEqual(['complete', 'no_show']);
			expect(acoes.every((a) => a.disabled)).toBe(true);
			expect(acoes[0].title).toBe('Disponível após o horário da sessão');
		});

		it('depois de começar, os dois liberam', () => {
			const acoes = participantActions(previsto, appt(), '2026-07-20T17:00:00Z');
			expect(acoes.every((a) => !a.disabled)).toBe(true);
		});

		it('presença resolvida oferece só desfazer — e sem gate de horário', () => {
			const acoes = participantActions(
				{ ...previsto, status: 'concluida' },
				appt({ status: 'concluido' }),
				'2026-07-20T09:00:00Z'
			);
			expect(acoes.map((a) => a.kind)).toEqual(['reopen']);
			expect(acoes[0].disabled).toBe(false);
		});

		it('bloco cancelado não oferece ação nenhuma (o guard block_not_open do servidor)', () => {
			expect(
				participantActions(previsto, appt({ status: 'cancelado' }), '2026-07-20T17:00:00Z')
			).toEqual([]);
		});

		it('presença cancelada (participante removido do bloco) também não oferece ação', () => {
			const acoes = participantActions(
				{ ...previsto, status: 'cancelada' },
				appt(),
				'2026-07-20T17:00:00Z'
			);
			expect(acoes).toEqual([]);
		});

		it('resolvedCount conta só o que foi resolvido', () => {
			expect(
				resolvedCount([
					previsto,
					{ ...previsto, patient_id: 'p2', status: 'concluida' },
					{ ...previsto, patient_id: 'p3', status: 'faltou' },
					{ ...previsto, patient_id: 'p4', status: 'cancelada' }
				])
			).toBe(2);
		});
	});

	// O cartão dizia só horário, nome e tipo: um bloco de pacote era indistinguível de um avulso,
	// e "que sessão é esta?" só se respondia abrindo a ficha do paciente.
	describe('packageBadge', () => {
		const avulso: Participant = {
			patient_id: 'pac1',
			status: 'prevista',
			falta_justificada: false,
			motivo: null,
			package_id: null,
			package: null,
			resposta: null
		};

		const doPacote: Participant = {
			...avulso,
			package_id: 'k1',
			package: { nome: 'Pilates 10', sessao: 3, total: 10, falta_punitiva: true }
		};

		it('sessão avulsa não tem selo', () => {
			expect(packageBadge(appt({ participants: [avulso] }))).toBeNull();
			expect(packageBadge(appt())).toBeNull();
		});

		it('a sessão de pacote diz a posição e o total', () => {
			const selo = packageBadge(appt({ participants: [doPacote] }));
			expect(selo?.label).toBe('3/10');
			expect(selo?.title).toBe('Pacote Pilates 10 · sessão 3 de 10');
		});

		// O pacote é do participante (D11): numa turma cada um consome do seu, e um "3/10" solto
		// no cartão não diria de quem é. Vira contagem — e o número só muda de significado junto
		// com o rótulo, nunca calado.
		it('turma com mais de um em pacote conta cabeças, não sessões', () => {
			const selo = packageBadge(
				appt({
					participants: [
						doPacote,
						{
							...doPacote,
							patient_id: 'pac2',
							package: { nome: 'RPG 8', sessao: 1, total: 8, falta_punitiva: false }
						},
						avulso
					]
				})
			);
			expect(selo?.label).toBe('2');
			expect(selo?.title).toBe('2 participantes em pacote');
		});

		// Presença cancelada saiu do bloco (mesma regra do `statusSignal`): o pacote dela não é
		// mais desta sessão.
		it('presença cancelada não conta como pacote do bloco', () => {
			expect(packageBadge(appt({ participants: [{ ...doPacote, status: 'cancelada' }] }))).toBeNull();
		});

		// `sessao` chega nulo se o servidor não carregou o calculado (uma porta lateral do bloco).
		// O selo continua dizendo o que sabe — "isto é pacote" — sem inventar número.
		it('sem a posição, o selo existe mas não mente', () => {
			const selo = packageBadge(
				appt({
					participants: [
						{
							...doPacote,
							package: { nome: 'Pilates 10', sessao: null, total: 10, falta_punitiva: true }
						}
					]
				})
			);
			expect(selo?.label).toBeNull();
			expect(selo?.title).toBe('Pacote Pilates 10');
		});
	});

	// A resposta do paciente ao link (doc 52 §5) era gravada e só existia na timeline do drawer:
	// para saber quem confirmou era preciso abrir um bloco por vez. O card é onde a recepção olha.
	describe('replyBadges', () => {
		const mudo: Participant = {
			patient_id: 'pac1',
			status: 'prevista',
			falta_justificada: false,
			motivo: null,
			package_id: null,
			package: null,
			resposta: null
		};

		const confirmou: Participant = { ...mudo, resposta: 'confirmou' };

		it('quem não respondeu não põe sinal nenhum no card', () => {
			expect(replyBadges(appt({ participants: [mudo] }))).toEqual([]);
			expect(replyBadges(appt())).toEqual([]);
		});

		it('a confirmação é a estrela, sem número na sessão individual', () => {
			const [selo, ...resto] = replyBadges(appt({ participants: [confirmou] }));

			expect(selo.kind).toBe('confirmou');
			expect(selo.label).toBeNull();
			expect(selo.title).toBe('O paciente confirmou presença');
			expect(resto).toEqual([]);
		});

		// Mesma forma do `packageBadge`: numa turma o número é o rótulo, porque a estrela sozinha
		// não diria quantos dos quatro confirmaram.
		it('na turma o número conta cabeças', () => {
			const [selo] = replyBadges(
				appt({
					participants: [confirmou, { ...confirmou, patient_id: 'pac2' }, mudo]
				})
			);

			expect(selo.label).toBe('2');
			expect(selo.title).toBe('2 confirmaram presença');
		});

		// O pedido de remarcação é o que EXIGE ação, então vem primeiro — a mesma precedência de
		// conflito antes de encaixe na linha 1 do cartão.
		it('quem pediu remarcação vem antes de quem confirmou', () => {
			const selos = replyBadges(
				appt({
					participants: [confirmou, { ...mudo, patient_id: 'pac2', resposta: 'quer_remarcar' }]
				})
			);

			expect(selos.map((s) => s.kind)).toEqual(['quer_remarcar', 'confirmou']);
			expect(selos[0].title).toBe('O paciente pediu para remarcar');
		});

		// Mesma regra do `statusSignal` e do `packageBadge`: presença cancelada saiu do bloco, e a
		// confirmação que ela deu não é mais sobre esta sessão.
		it('presença cancelada não põe estrela no bloco', () => {
			expect(replyBadges(appt({ participants: [{ ...confirmou, status: 'cancelada' }] }))).toEqual(
				[]
			);
		});
	});

	// "Isso vai descontar do pacote dela?" — a pergunta que a recepção faz em voz alta quando
	// alguém falta. A regra (RN-29/30/31) é do servidor; aqui só se escreve o que ela decidiu.
	describe('packageDebit', () => {
		const base: Participant = {
			patient_id: 'pac1',
			status: 'prevista',
			falta_justificada: false,
			motivo: null,
			package_id: 'k1',
			package: { nome: 'Pilates 10', sessao: 3, total: 10, falta_punitiva: true },
			resposta: null
		};

		const semPacote: Participant = { ...base, package_id: null, package: null };

		it('sem pacote não há o que dizer', () => {
			expect(packageDebit(semPacote)).toBeNull();
		});

		it('presença cancelada saiu do bloco — não fala do pacote dela', () => {
			expect(packageDebit({ ...base, status: 'cancelada' })).toBeNull();
		});

		it('concluída debitou', () => {
			expect(packageDebit({ ...base, status: 'concluida' })).toEqual({
				label: 'Sessão debitada do pacote',
				tone: 'success'
			});
		});

		it('falta punitiva sem justificativa debita, e o tom avisa', () => {
			expect(packageDebit({ ...base, status: 'faltou' })).toEqual({
				label: 'Esta falta debitou 1 sessão',
				tone: 'danger'
			});
		});

		it('justificar devolve a sessão — é o que o switch do drawer faz', () => {
			expect(packageDebit({ ...base, status: 'faltou', falta_justificada: true })).toEqual({
				label: 'Falta justificada — não debitou',
				tone: 'success'
			});
		});

		// `falta_punitiva` é do PACOTE e imutável (RN-30/31): num não-punitivo a falta nunca
		// debita, justificada ou não.
		it('pacote não punitivo não debita falta nenhuma', () => {
			const naoPunitivo = {
				...base,
				status: 'faltou' as const,
				package: { ...base.package!, falta_punitiva: false }
			};
			expect(packageDebit(naoPunitivo)?.tone).toBe('success');
			expect(packageDebit(naoPunitivo)?.label).toBe('Falta não debita neste pacote');
		});

		// Antes do desfecho a frase é PREVISÃO, e é aí que ela vale: dizer "faltar hoje consome
		// uma das 10" muda a conversa com o paciente ANTES da falta. Tom neutro — não aconteceu.
		it('antes do desfecho, prevê sem alarmar', () => {
			expect(packageDebit(base)).toEqual({
				label: 'Falta debita 1 sessão deste pacote',
				tone: null
			});
		});
	});
});

// ACC-03 (doc 83, WCAG 2.1.1): criar agendamento só existia por ponteiro. O botão "Novo
// agendamento" precisa de um preset, e este é o palpite — primeiro profissional VISÍVEL e o
// começo do expediente dele.
describe('presetDoBotao', () => {
	const profs = [{ id: 'p1' }, { id: 'p2' }];
	const disp = [
		{ professional_id: 'p1', date: '2026-08-03', periods: [['09:30', '12:00']] as Period[] },
		{ professional_id: 'p2', date: '2026-08-03', periods: [['13:00', '18:00']] as Period[] }
	];

	it('pega o primeiro profissional e o início do expediente dele', () => {
		expect(presetDoBotao(profs, [], disp)).toEqual({ professional_id: 'p1', hora: '09:30' });
	});

	it('respeita o filtro da sidebar — profissional oculto não é preselecionado', () => {
		expect(presetDoBotao(profs, ['p1'], disp)).toEqual({ professional_id: 'p2', hora: '13:00' });
	});

	it('sem expediente no dia, cai em 08:00 em vez de campo vazio', () => {
		const semGrade = [{ professional_id: 'p1', date: '2026-08-03', periods: [] as Period[] }];
		expect(presetDoBotao(profs, [], semGrade)).toEqual({ professional_id: 'p1', hora: '08:00' });
		// Profissional sem entrada nenhuma na disponibilidade também.
		expect(presetDoBotao(profs, [], [])).toEqual({ professional_id: 'p1', hora: '08:00' });
	});

	it('devolve null quando TODOS estão ocultos — não há coluna para abrir o modal', () => {
		expect(presetDoBotao(profs, ['p1', 'p2'], disp)).toBeNull();
		expect(presetDoBotao([], [], disp)).toBeNull();
	});
});
