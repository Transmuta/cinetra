import { describe, it, expect } from 'vitest';
import {
	PRIORITY_META,
	PRIORITY_ORDER,
	TIME_WINDOW_LABEL,
	ruleLabel,
	rulePrefix,
	ruleExpired,
	slotDateLabel,
	sortByPriority,
	priorityRank,
	parsePriorityFilter,
	priorityCounts,
	canManageWaitlist,
	dispItems,
	hasSlots,
	type Entry,
	type Rule,
	type Slot,
	type Priority,
	type TimeWindow
} from './waitlist';

// Fábrica enxuta: só o que os helpers puros olham (prioridade e o carimbo de entrada).
function entry(prio: Priority, inserted_at = '2026-07-20T10:00:00Z'): Entry {
	return {
		id: `e-${prio}-${inserted_at}`,
		prio,
		janela: 'qualquer',
		obs: null,
		professional_ids: [],
		dias_na_fila: 0,
		rules: [],
		patient: { id: 'p1', nome: 'Maria', tel: null, ativo: true, faltas: 0 },
		inserted_at
	};
}

describe('PRIORITY_ORDER / priorityRank', () => {
	it('vai do mais urgente ao menos', () => {
		expect(PRIORITY_ORDER).toEqual(['urgente', 'alta', 'normal', 'baixa']);
	});

	it('o posto reflete a ordem (urgente = 0)', () => {
		expect(priorityRank('urgente')).toBe(0);
		expect(priorityRank('baixa')).toBe(3);
	});

	it('todo nível tem cor e rótulo (protótipo prioMeta)', () => {
		expect(PRIORITY_META.urgente).toEqual({ label: 'Urgente', color: '#E5484D' });
		expect(PRIORITY_META.baixa.color).toBe('#AEB6BE');
	});
});

describe('sortByPriority', () => {
	it('ordena por urgência, não pela string do enum (que o Postgres ordenaria alfabética)', () => {
		const list = [entry('normal'), entry('urgente'), entry('baixa'), entry('alta')];
		expect(sortByPriority(list).map((e) => e.prio)).toEqual(['urgente', 'alta', 'normal', 'baixa']);
	});

	it('empate de prioridade desempata pelo mais antigo na fila', () => {
		const nova = entry('alta', '2026-07-20T12:00:00Z');
		const antiga = entry('alta', '2026-07-19T08:00:00Z');
		expect(sortByPriority([nova, antiga]).map((e) => e.inserted_at)).toEqual([
			'2026-07-19T08:00:00Z',
			'2026-07-20T12:00:00Z'
		]);
	});

	it('não muta a lista recebida', () => {
		const list = [entry('baixa'), entry('urgente')];
		const antes = list.map((e) => e.prio);
		sortByPriority(list);
		expect(list.map((e) => e.prio)).toEqual(antes);
	});
});

describe('TIME_WINDOW_LABEL', () => {
	it('traduz os átomos sem acento para o rótulo com acento', () => {
		expect(TIME_WINDOW_LABEL.manha).toBe('Manhã');
		expect(TIME_WINDOW_LABEL.tarde).toBe('Tarde');
		expect(TIME_WINDOW_LABEL.qualquer).toBe('Qualquer');
	});
});

describe('ruleLabel', () => {
	const semana: Rule = { tipo: 'semana', dows: [2, 1], data: null, periodos: [['09:00', '11:00']] };

	it('semana: dias ordenados por "/" + faixas (com travessão)', () => {
		expect(ruleLabel(semana)).toBe('Seg/Ter · 09:00–11:00');
	});

	it('semana com várias faixas junta por vírgula', () => {
		expect(
			ruleLabel({ tipo: 'semana', dows: [3], data: null, periodos: [['08:00', '10:00'], ['14:00', '16:00']] })
		).toBe('Qua · 08:00–10:00, 14:00–16:00');
	});

	it('data: DD/MM + faixas', () => {
		expect(
			ruleLabel({ tipo: 'data', dows: [], data: '2026-07-15', periodos: [['08:00', '12:00']] })
		).toBe('15/07 · 08:00–12:00');
	});

	it('data sem data preenchida vira travessão', () => {
		expect(ruleLabel({ tipo: 'data', dows: [], data: null, periodos: [['08:00', '12:00']] })).toBe('—');
	});
});

describe('slotDateLabel', () => {
	it('usa o dia da semana do slot (não reparseia a data) + DD/MM', () => {
		// dow=4 → quinta; "2026-06-25" → 25/06.
		expect(slotDateLabel({ date: '2026-06-25', dow: 4 })).toBe('qui 25/06');
	});

	it('domingo é dow 0', () => {
		expect(slotDateLabel({ date: '2026-07-05', dow: 0 })).toBe('dom 05/07');
	});
});

describe('rulePrefix', () => {
	it('semana → dias ordenados por "/", sem faixas', () => {
		expect(rulePrefix({ tipo: 'semana', dows: [2, 1], data: null, periodos: [['09:00', '11:00']] })).toBe('Seg/Ter');
	});

	it('data → só DD/MM (a vaga já traz o horário)', () => {
		expect(rulePrefix({ tipo: 'data', dows: [], data: '2026-06-25', periodos: [['08:00', '12:00']] })).toBe('25/06');
	});

	it('data sem data preenchida vira travessão', () => {
		expect(rulePrefix({ tipo: 'data', dows: [], data: null, periodos: [] })).toBe('—');
	});
});

describe('ruleExpired', () => {
	const rule = (data: string | null): Rule => ({ tipo: 'data', dows: [], data, periodos: [['08:00', '12:00']] });

	it('regra :data anterior a hoje expira', () => {
		expect(ruleExpired(rule('2026-06-24'), '2026-06-25')).toBe(true);
	});

	it('regra :data de hoje ou futura não expira (comparação de fronteira)', () => {
		expect(ruleExpired(rule('2026-06-25'), '2026-06-25')).toBe(false);
		expect(ruleExpired(rule('2026-07-01'), '2026-06-25')).toBe(false);
	});

	it('regra :semana nunca expira; :data sem data também não', () => {
		expect(ruleExpired({ tipo: 'semana', dows: [1], data: null, periodos: [] }, '2026-06-25')).toBe(false);
		expect(ruleExpired(rule(null), '2026-06-25')).toBe(false);
	});
});

describe('hasSlots', () => {
	it('true só com ao menos uma vaga', () => {
		expect(hasSlots([slot(0)])).toBe(true);
		expect(hasSlots([])).toBe(false);
		expect(hasSlots(undefined)).toBe(false);
	});
});

// Fábrica de vaga: só os campos que a célula olha (`rule_index`, `freed`, data/horário do rótulo).
function slot(rule_index: number | null, over: Partial<Slot> = {}): Slot {
	return {
		date: '2026-06-25',
		start: 540,
		dur: 50,
		professional_id: 'p1',
		dow: 4,
		rule_index,
		freed: false,
		...over
	};
}

function withRules(rules: Rule[], janela: TimeWindow = 'qualquer'): Entry {
	return {
		id: 'e1',
		prio: 'normal',
		janela,
		obs: null,
		professional_ids: [],
		dias_na_fila: 0,
		rules,
		patient: { id: 'p1', nome: 'Maria', tel: null, ativo: true, faltas: 0 },
		inserted_at: '2026-06-20T10:00:00Z'
	};
}

const TODAY = '2026-06-25';
const semana = (dows: number[]): Rule => ({ tipo: 'semana', dows, data: null, periodos: [['09:00', '11:00']] });
const dataRule = (data: string): Rule => ({ tipo: 'data', dows: [], data, periodos: [['09:00', '11:00']] });

describe('dispItems', () => {
	it('sem regras e sem vaga: janela "Qualquer horário" + marcador "sem vaga"', () => {
		expect(dispItems(withRules([]), [], TODAY)).toEqual([
			{ kind: 'neutral', label: 'Qualquer horário', expired: false, mono: false },
			{ kind: 'none' }
		]);
	});

	it('sem regras COM vaga: a janela vira chip de oferta "Qualquer"', () => {
		const s = slot(null);
		expect(dispItems(withRules([], 'manha'), [s], TODAY)).toEqual([{ kind: 'match', label: 'Manhã', slot: s }]);
	});

	it('regra que casou (pelo rule_index) vira chip de oferta com o prefixo curto', () => {
		const s = slot(0);
		const items = dispItems(withRules([semana([1, 2])]), [s], TODAY);
		expect(items[0]).toEqual({ kind: 'match', label: 'Seg/Ter', slot: s });
	});

	it('regra sem vaga fica neutra (mono); regra :data no passado fica riscada (expired)', () => {
		const items = dispItems(withRules([semana([1]), dataRule('2026-06-24')]), [], TODAY);
		expect(items).toEqual([
			{ kind: 'neutral', label: 'Seg · 09:00–11:00', expired: false, mono: true },
			{ kind: 'neutral', label: '24/06 · 09:00–11:00', expired: true, mono: true },
			{ kind: 'none' }
		]);
	});

	it('a janela (não-qualquer) entra como chip antes das regras', () => {
		const items = dispItems(withRules([semana([1])], 'tarde'), [], TODAY);
		expect(items[0]).toEqual({ kind: 'neutral', label: 'Tarde', expired: false, mono: false });
	});
});

describe('parsePriorityFilter', () => {
	it('aceita as quatro prioridades e "todas"', () => {
		expect(parsePriorityFilter('urgente')).toBe('urgente');
		expect(parsePriorityFilter('todas')).toBe('todas');
	});

	it('valor desconhecido (ou ausente) cai em "todas"', () => {
		expect(parsePriorityFilter('lixo')).toBe('todas');
		expect(parsePriorityFilter(null)).toBe('todas');
	});
});

describe('priorityCounts', () => {
	it('conta por prioridade + o total em "todas"', () => {
		const c = priorityCounts([entry('urgente'), entry('urgente'), entry('normal')]);
		expect(c).toEqual({ todas: 3, urgente: 2, alta: 0, normal: 1, baixa: 0 });
	});
});

describe('canManageWaitlist', () => {
	// A8: administrar a fila é dos quatro papéis — inclusive profissional (a fila não é "dele",
	// mas ele mexe na fila da clínica). É o que separa este predicado de canManageMembers.
	it('todos os quatro papéis podem', () => {
		for (const papel of ['owner', 'admin', 'recepcao', 'profissional'] as const) {
			expect(canManageWaitlist(papel)).toBe(true);
		}
	});

	it('sem papel, não pode', () => {
		expect(canManageWaitlist(null)).toBe(false);
		expect(canManageWaitlist(undefined)).toBe(false);
	});
});
