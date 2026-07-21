import { describe, it, expect } from 'vitest';
import {
	PRIORITY_META,
	PRIORITY_ORDER,
	TIME_WINDOW_LABEL,
	ruleLabel,
	slotDateLabel,
	sortByPriority,
	priorityRank,
	parsePriorityFilter,
	priorityCounts,
	canManageWaitlist,
	type Entry,
	type Rule,
	type Priority
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
