import { describe, it, expect } from 'vitest';
import {
	parseResource,
	parsePage,
	pageLabel,
	canViewAudit,
	actionLabel,
	fieldLabel,
	formatValue,
	formatAt,
	dayKey,
	dayHeading,
	groupByDay,
	type AuditEntry
} from './audit';

const TZ = 'America/Sao_Paulo';

function entry(over: Partial<AuditEntry> = {}): AuditEntry {
	return {
		id: 'v1',
		resource: 'appointment',
		record_id: 'a1',
		action: 'schedule',
		action_type: 'create',
		at: '2026-07-20T14:30:00Z',
		status: 'agendado',
		actor: { id: 'u1', nome: 'Ana' },
		starts_at: '2026-07-20T11:00:00Z',
		professional: { id: 'p1', nome: 'Dra. Bea' },
		patient: null,
		appointment_id: null,
		diff: [],
		...over
	};
}

describe('parseResource / parsePage', () => {
	it('resource cai em appointment para qualquer valor que não seja attendance', () => {
		expect(parseResource('attendance')).toBe('attendance');
		expect(parseResource('appointment')).toBe('appointment');
		expect(parseResource(null)).toBe('appointment');
		expect(parseResource('lixo')).toBe('appointment');
	});

	it('page inválida é a página 1', () => {
		expect(parsePage('3')).toBe(3);
		expect(parsePage('0')).toBe(1);
		expect(parsePage('-2')).toBe(1);
		expect(parsePage('abc')).toBe(1);
		expect(parsePage(null)).toBe(1);
	});
});

describe('pageLabel', () => {
	it('"1–50", sem o total (D-Aud1)', () => {
		expect(pageLabel({ limit: 50, offset: 0, more: true }, 50)).toBe('1–50');
		expect(pageLabel({ limit: 50, offset: 50, more: true }, 50)).toBe('51–100');
	});

	it('vazio quando não há resultado', () => {
		expect(pageLabel({ limit: 50, offset: 0, more: false }, 0)).toBe('');
	});
});

describe('canViewAudit', () => {
	it('só owner e admin', () => {
		expect(canViewAudit('owner')).toBe(true);
		expect(canViewAudit('admin')).toBe(true);
		expect(canViewAudit('recepcao')).toBe(false);
		expect(canViewAudit('profissional')).toBe(false);
		expect(canViewAudit(null)).toBe(false);
		expect(canViewAudit(undefined)).toBe(false);
	});
});

describe('actionLabel', () => {
	it('traduz por recurso — a mesma :create difere', () => {
		expect(actionLabel({ resource: 'appointment', action: 'schedule' })).toBe('Agendou');
		expect(actionLabel({ resource: 'appointment', action: 'cancel' })).toBe('Cancelou');
		expect(actionLabel({ resource: 'appointment', action: 'reschedule' })).toBe('Remarcou');
		expect(actionLabel({ resource: 'attendance', action: 'create' })).toBe('Entrou na turma');
		expect(actionLabel({ resource: 'attendance', action: 'transition' })).toBe('Mudou a presença');
	});

	it('ação desconhecida cai no nome cru (não quebra)', () => {
		expect(actionLabel({ resource: 'appointment', action: 'novo_verbo' })).toBe('novo_verbo');
	});
});

describe('fieldLabel', () => {
	it('rótulos pt-BR; campo desconhecido cru', () => {
		expect(fieldLabel('status')).toBe('Situação');
		expect(fieldLabel('starts_at')).toBe('Início');
		expect(fieldLabel('cancel_reason')).toBe('Motivo do cancelamento');
		expect(fieldLabel('campo_novo')).toBe('campo_novo');
	});
});

describe('formatValue', () => {
	it('status do agendamento reusa os rótulos da agenda', () => {
		expect(formatValue('appointment', 'status', 'agendado', TZ)).toBe('Agendado');
		expect(formatValue('appointment', 'status', 'cancelado', TZ)).toBe('Cancelado');
		expect(formatValue('appointment', 'status', 'concluido', TZ)).toBe('Concluído');
	});

	it('status do participante tem os próprios rótulos', () => {
		expect(formatValue('attendance', 'status', 'prevista', TZ)).toBe('Prevista');
		expect(formatValue('attendance', 'status', 'faltou', TZ)).toBe('Faltou');
	});

	it('starts_at vira hora local da clínica', () => {
		// 12:00Z em São Paulo (UTC-3) = 09:00.
		expect(formatValue('appointment', 'starts_at', '2026-07-20T12:00:00Z', TZ)).toBe('20/07/2026 09:00');
	});

	it('booleano vira Sim/Não; nulo/vazio vira travessão', () => {
		expect(formatValue('appointment', 'encaixe', true, TZ)).toBe('Sim');
		expect(formatValue('appointment', 'encaixe', false, TZ)).toBe('Não');
		expect(formatValue('appointment', 'obs', null, TZ)).toBe('—');
		expect(formatValue('appointment', 'obs', '', TZ)).toBe('—');
	});

	it('texto livre passa como está', () => {
		expect(formatValue('appointment', 'obs', 'trazer exame', TZ)).toBe('trazer exame');
	});

	it('status desconhecido cai no valor cru', () => {
		expect(formatValue('appointment', 'status', 'inexistente', TZ)).toBe('inexistente');
	});
});

describe('formatAt / dayKey / dayHeading (fuso da clínica)', () => {
	it('formata no fuso da clínica, não do processo', () => {
		expect(formatAt('2026-07-20T14:32:00Z', TZ)).toBe('20/07/2026 11:32');
	});

	it('iso inválido volta como veio', () => {
		expect(formatAt('nao-e-data', TZ)).toBe('nao-e-data');
	});

	it('dayKey usa o dia LOCAL — a virada de meia-noite conta o fuso', () => {
		// 02:00Z de 20/07 é 23:00 de 19/07 em São Paulo.
		expect(dayKey('2026-07-20T02:00:00Z', TZ)).toBe('2026-07-19');
		expect(dayKey('2026-07-20T14:00:00Z', TZ)).toBe('2026-07-20');
	});

	it('dayHeading em pt-BR', () => {
		expect(dayHeading('2026-07-20')).toBe('20 de julho de 2026');
		expect(dayHeading('2026-01-05')).toBe('5 de janeiro de 2026');
	});
});

describe('groupByDay', () => {
	it('agrupa entradas consecutivas do mesmo dia, preservando a ordem', () => {
		const entries = [
			entry({ id: 'v3', at: '2026-07-20T14:00:00Z' }),
			entry({ id: 'v2', at: '2026-07-20T10:00:00Z' }),
			entry({ id: 'v1', at: '2026-07-19T10:00:00Z' })
		];
		const groups = groupByDay(entries, TZ);

		expect(groups).toHaveLength(2);
		expect(groups[0].day).toBe('2026-07-20');
		expect(groups[0].heading).toBe('20 de julho de 2026');
		expect(groups[0].entries.map((e) => e.id)).toEqual(['v3', 'v2']);
		expect(groups[1].day).toBe('2026-07-19');
		expect(groups[1].entries.map((e) => e.id)).toEqual(['v1']);
	});

	it('lista vazia → nenhum grupo', () => {
		expect(groupByDay([], TZ)).toEqual([]);
	});
});
