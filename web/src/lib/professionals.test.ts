import { describe, it, expect } from 'vitest';
import {
	profColor,
	especialidadeLabel,
	filterByStatus,
	countByStatus,
	searchProfessionals,
	resolveWeekday,
	attendanceSummary,
	periodsWithinClinic,
	initialGrade,
	buildDays,
	hasAttendingDay,
	weekToHoursRows,
	professionalNameMap,
	CONTRACT_LABELS,
	type Professional,
	type HoursRow
} from './professionals';

// Expediente do seed: Seg–Sex 08–12/13–18, Sáb manhã, Dom fechado.
const CLINIC: HoursRow[] = [
	{ dow: 0, modo: null, periods: [] },
	{ dow: 1, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 2, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 3, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 4, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 5, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 6, modo: null, periods: [['08:00', '12:00']] }
];

function prof(overrides: Partial<Professional> = {}): Professional {
	return {
		id: 'p1', nome: 'Dra. Marina', nome_exibicao: null, nascimento: null, cpf: null, rg: null,
		estado_civil: null, tel: null, email: null, cep: null, endereco: null, numero: null,
		complemento: null, bairro: null, cidade: null, uf: null, emergencia_nome: null,
		emergencia_tel: null, profissao: null, crefito: null, registro_uf: null, ano_conclusao: null,
		especialidades: [], sub: null, vinculo: null, razao_social: null, cnpj: null, banco: null,
		agencia: null, conta: null, conta_tipo: null, pix: null, cor_indice: 1,
		segue_horario_clinica: true, ativo: true, weekly_hours: [], exceptions: [],
		...overrides
	};
}

describe('profColor', () => {
	it('índice 1-based com wrap na paleta de 7', () => {
		expect(profColor(1)).toBe(profColor(8));
		expect(profColor(2)).not.toBe(profColor(1));
	});
});

describe('CONTRACT_LABELS', () => {
	it('rotula os vínculos', () => {
		expect(CONTRACT_LABELS.pj).toBe('PJ');
		expect(CONTRACT_LABELS.autonomo).toBe('Autônomo');
		expect(CONTRACT_LABELS.clt).toBe('CLT');
	});
});

describe('especialidadeLabel', () => {
	it('1ª especialidade + "+N", ou sub, ou "—"', () => {
		expect(especialidadeLabel(prof({ especialidades: ['Ortopedia', 'Desportiva'] }))).toBe('Ortopedia +1');
		expect(especialidadeLabel(prof({ especialidades: ['Pilates'] }))).toBe('Pilates');
		expect(especialidadeLabel(prof({ especialidades: [], sub: 'Neuro' }))).toBe('Neuro');
		expect(especialidadeLabel(prof({ especialidades: [], sub: null }))).toBe('—');
	});
});

describe('filtro por status', () => {
	const list = [prof({ id: 'a', ativo: true }), prof({ id: 'b', ativo: false })];

	it('ativos / inativos / todos', () => {
		expect(filterByStatus(list, 'ativos').map((p) => p.id)).toEqual(['a']);
		expect(filterByStatus(list, 'inativos').map((p) => p.id)).toEqual(['b']);
		expect(filterByStatus(list, 'todos')).toHaveLength(2);
	});

	it('conta por status', () => {
		expect(countByStatus(list)).toEqual({ todos: 2, ativos: 1, inativos: 1 });
	});
});

describe('busca', () => {
	const list = [
		prof({ id: 'a', nome: 'Dra. Marina Lopes', crefito: 'CREFITO 3/123456-F', especialidades: ['Ortopedia'], cpf: '123.456.789-00', tel: '(11) 98123-4451' }),
		prof({ id: 'b', nome: 'Dr. Rafael Couto', sub: 'Neurologia' })
	];

	it('termo vazio devolve tudo', () => {
		expect(searchProfessionals(list, '  ')).toHaveLength(2);
	});
	it('casa por nome, especialidade e CREFITO', () => {
		expect(searchProfessionals(list, 'marina').map((p) => p.id)).toEqual(['a']);
		expect(searchProfessionals(list, 'neuro').map((p) => p.id)).toEqual(['b']);
		expect(searchProfessionals(list, '123456').map((p) => p.id)).toEqual(['a']);
	});
	it('casa por dígitos do CPF/telefone', () => {
		expect(searchProfessionals(list, '98123').map((p) => p.id)).toEqual(['a']);
		expect(searchProfessionals(list, '12345678900').map((p) => p.id)).toEqual(['a']);
	});
});

describe('periodsWithinClinic (invariante prof ⊆ clínica)', () => {
	const clinic = [['08:00', '12:00'], ['13:00', '18:00']] as [string, string][];
	it('cabe dentro de um período', () => {
		expect(periodsWithinClinic([['09:00', '11:00']], clinic)).toBe(true);
		expect(periodsWithinClinic([['13:00', '18:00']], clinic)).toBe(true);
	});
	it('não cabe: antes da abertura, no almoço, ou depois', () => {
		expect(periodsWithinClinic([['07:00', '09:00']], clinic)).toBe(false);
		expect(periodsWithinClinic([['12:00', '13:00']], clinic)).toBe(false);
		expect(periodsWithinClinic([['17:00', '19:00']], clinic)).toBe(false);
	});
	it('clínica fechada só aceita vazio', () => {
		expect(periodsWithinClinic([], [])).toBe(true);
		expect(periodsWithinClinic([['09:00', '10:00']], [])).toBe(false);
	});
});

describe('resolveWeekday', () => {
	it('segue a clínica: herda o expediente', () => {
		expect(resolveWeekday(prof(), 1, CLINIC)).toEqual([['08:00', '12:00'], ['13:00', '18:00']]);
		expect(resolveWeekday(prof(), 0, CLINIC)).toEqual([]); // domingo fechado
	});
	it('custom vence; fechado zera; herda cai na clínica', () => {
		const p = prof({
			segue_horario_clinica: false,
			weekly_hours: [
				{ dow: 1, modo: 'custom', periods: [['09:00', '11:00']] },
				{ dow: 2, modo: 'fechado', periods: [] },
				{ dow: 3, modo: 'herda', periods: [] }
			]
		});
		expect(resolveWeekday(p, 1, CLINIC)).toEqual([['09:00', '11:00']]);
		expect(resolveWeekday(p, 2, CLINIC)).toEqual([]);
		expect(resolveWeekday(p, 3, CLINIC)).toEqual([['08:00', '12:00'], ['13:00', '18:00']]);
	});
	it('não segue e sem linha: não atende', () => {
		expect(resolveWeekday(prof({ segue_horario_clinica: false }), 1, CLINIC)).toEqual([]);
	});
});

describe('attendanceSummary', () => {
	it('segue a clínica e sem override: "Seg–Sex" + Segue a clínica', () => {
		const s = attendanceSummary(prof(), CLINIC);
		expect(s.days).toBe('Seg–Sex');
		expect(s.followsClinic).toBe(true);
		expect(s.hours).toBe('08:00–12:00, 13:00–18:00');
	});
	it('dias parciais listam abreviações', () => {
		const p = prof({
			segue_horario_clinica: false,
			weekly_hours: [
				{ dow: 1, modo: 'custom', periods: [['09:00', '10:00']] },
				{ dow: 3, modo: 'custom', periods: [['09:00', '10:00']] }
			]
		});
		expect(attendanceSummary(p, CLINIC).days).toBe('Seg, Qua');
		expect(attendanceSummary(p, CLINIC).followsClinic).toBe(false);
	});
	it('sem atendimento nenhum: "—"', () => {
		expect(attendanceSummary(prof({ segue_horario_clinica: false }), CLINIC).days).toBe('—');
	});
});

describe('initialGrade', () => {
	it('novo: pré-preenche dias abertos com cópia da clínica, fecha o domingo', () => {
		const g = initialGrade(null, CLINIC);
		expect(g[1]).toEqual([['08:00', '12:00'], ['13:00', '18:00']]);
		expect(g[0]).toBeNull();
	});
	it('edição: custom→períodos, fechado→null', () => {
		const p = prof({
			weekly_hours: [
				{ dow: 1, modo: 'custom', periods: [['09:00', '10:00']] },
				{ dow: 2, modo: 'fechado', periods: [] }
			]
		});
		const g = initialGrade(p, CLINIC);
		expect(g[1]).toEqual([['09:00', '10:00']]);
		expect(g[2]).toBeNull();
	});
});

describe('buildDays', () => {
	it('seguindo a clínica: 7 dias :herda', () => {
		const days = buildDays(true, initialGrade(null, CLINIC), CLINIC);
		expect(days).toHaveLength(7);
		expect(days.every((d) => d.modo === 'herda' && d.periods.length === 0)).toBe(true);
	});
	it('não seguindo: custom onde há períodos, fechado onde não (e onde a clínica fecha)', () => {
		const grade = { ...initialGrade(null, CLINIC), 1: [['09:00', '10:00']] as [string, string][], 2: null };
		const days = buildDays(false, grade, CLINIC);
		const byDow = Object.fromEntries(days.map((d) => [d.dow, d]));
		expect(byDow[1].modo).toBe('custom');
		expect(byDow[2].modo).toBe('fechado');
		expect(byDow[0].modo).toBe('fechado'); // domingo: clínica fechada
	});
});

describe('weekToHoursRows', () => {
	it('converte o mapa {dow => periods} da clínica em linhas HoursRow', () => {
		// Object.entries ordena chaves inteiras numericamente (0 antes de 1); a ordem é
		// irrelevante para os consumidores (todos resolvem por `dow`).
		const rows = weekToHoursRows({ '1': [['08:00', '12:00']], '0': [] });
		expect(rows).toEqual([
			{ dow: 0, modo: null, periods: [] },
			{ dow: 1, modo: null, periods: [['08:00', '12:00']] }
		]);
	});
});

describe('hasAttendingDay (horário obrigatório)', () => {
	it('seguindo a clínica sempre ok', () => {
		expect(hasAttendingDay(true, {}, CLINIC)).toBe(true);
	});
	it('não seguindo: precisa de ao menos um dia com períodos', () => {
		expect(hasAttendingDay(false, { 1: null, 2: null }, CLINIC)).toBe(false);
		expect(hasAttendingDay(false, { 1: [['09:00', '10:00']] }, CLINIC)).toBe(true);
	});
});

/**
 * O simétrico de `patientNameMap`, que já existia em `agenda.ts`. Este faltava, e por isso a
 * linha estava escrita à mão em `/pacientes` e em `/pacientes/[id]` — com o mesmo cast nas duas
 * (doc 94 §D-5).
 */
describe('professionalNameMap', () => {
	it('indexa por id', () => {
		expect(
			professionalNameMap([
				{ id: 'p1', nome: 'Marina Lopes' },
				{ id: 'p2', nome: 'Ana Silva' }
			])
		).toEqual({ p1: 'Marina Lopes', p2: 'Ana Silva' });
	});

	it('lista vazia devolve mapa vazio', () => {
		expect(professionalNameMap([])).toEqual({});
	});

	// A tela chama isto com `data.professionals`, que é opcional no `load` de algumas rotas.
	it('tolera ausência — a coluna fica sem nome, não quebra a tela', () => {
		expect(professionalNameMap(undefined)).toEqual({});
	});
});
