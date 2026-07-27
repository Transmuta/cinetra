import { describe, it, expect } from 'vitest';
import {
	parseResource,
	parsePage,
	parseAction,
	parsePeriod,
	periodRange,
	auditPageLabel,
	canViewAudit,
	actionLabel,
	actionOptions,
	entryHeadline,
	entryContext,
	activeChips,
	resourcePatch,
	auditHref,
	fieldLabel,
	formatValue,
	formatAt,
	formatTime,
	formatSession,
	dayKey,
	dayHeading,
	groupByDay,
} from './audit';
import { auditEntryFixture } from './testing/fixtures';

const TZ = 'America/Sao_Paulo';

// A fábrica mora em `$lib/testing/fixtures` (a casa que o projeto já tem): um campo novo em
// `AuditEntry` entra num lugar só.
const entry = auditEntryFixture;

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

describe('parseAction', () => {
	it('aceita só as ações DO RECURSO', () => {
		expect(parseAction('cancel', 'appointment')).toBe('cancel');
		expect(parseAction('mark_present', 'attendance')).toBe('mark_present');
	});

	// O eixo que mais engana: `cancel` existe no bloco e não na presença. Sem esta validação a
	// tela mostraria o chip "Cancelou" sobre uma lista que a API devolveu SEM filtro (a whitelist
	// de lá também vira filtro nulo, não 422).
	it('recusa a ação do OUTRO recurso e o lixo', () => {
		expect(parseAction('cancel', 'attendance')).toBeNull();
		expect(parseAction('mark_present', 'appointment')).toBeNull();
		expect(parseAction('nao_existe', 'appointment')).toBeNull();
		expect(parseAction(null, 'appointment')).toBeNull();
		expect(parseAction('', 'appointment')).toBeNull();
	});
});

describe('período', () => {
	it('valor inválido é "todo o histórico"', () => {
		expect(parsePeriod('7d')).toBe('7d');
		expect(parsePeriod('hoje')).toBe('hoje');
		expect(parsePeriod('30d')).toBe('30d');
		expect(parsePeriod('ano')).toBe('tudo');
		expect(parsePeriod(null)).toBe('tudo');
	});

	it('a janela é fechada no dia local da clínica', () => {
		expect(periodRange('hoje', '2026-07-20')).toEqual({ from: '2026-07-20', to: '2026-07-20' });
		expect(periodRange('7d', '2026-07-20')).toEqual({ from: '2026-07-14', to: '2026-07-20' });
		expect(periodRange('30d', '2026-07-20')).toEqual({ from: '2026-06-21', to: '2026-07-20' });
		expect(periodRange('tudo', '2026-07-20')).toBeNull();
	});

	// A API recusa janela de 31 dias ou mais (`validate_window`); um preset maior seria 422.
	it('nenhum preset chega no teto de 31 dias da API', () => {
		for (const p of ['hoje', '7d', '30d'] as const) {
			const r = periodRange(p, '2026-07-20')!;
			const dias = (Date.parse(r.to) - Date.parse(r.from)) / 86400000;
			expect(dias).toBeLessThan(31);
		}
	});
});

describe('pageLabel', () => {
	it('"1–50", sem o total (D-Aud1)', () => {
		expect(auditPageLabel({ limit: 50, offset: 0, more: true }, 50)).toBe('1–50');
		expect(auditPageLabel({ limit: 50, offset: 50, more: true }, 50, 2)).toBe('Página 2 · 51–100');
	});

	it('vazio quando não há resultado', () => {
		expect(auditPageLabel({ limit: 50, offset: 0, more: false }, 0)).toBe('');
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

describe('actionLabel / actionOptions', () => {
	it('traduz por recurso — a mesma :create difere', () => {
		expect(actionLabel({ resource: 'appointment', action: 'schedule' })).toBe('Agendou');
		expect(actionLabel({ resource: 'appointment', action: 'cancel' })).toBe('Cancelou');
		expect(actionLabel({ resource: 'attendance', action: 'create' })).toBe(
			'Adicionou ao atendimento'
		);
	});

	it('ação desconhecida cai no nome cru (não quebra)', () => {
		expect(actionLabel({ resource: 'appointment', action: 'novo_verbo' })).toBe('novo_verbo');
	});

	// Medido no banco de dev: `exclude`, `apply_participant_rollup`, `set_pkg_hold`,
	// `set_package`, `mark_present`, `mark_absent`, `reopen_attendance` e `justify_absence`
	// EXISTEM e não tinham rótulo — a tela exibia o átomo cru para a administração.
	it.each([
		['appointment', 'exclude'],
		['appointment', 'apply_participant_rollup'],
		['appointment', 'set_pkg_hold'],
		['attendance', 'set_package'],
		['attendance', 'mark_present'],
		['attendance', 'mark_absent'],
		['attendance', 'reopen_attendance'],
		['attendance', 'justify_absence'],
		['attendance', 'remove']
	] as const)('%s/%s tem rótulo em português', (resource, action) => {
		expect(actionLabel({ resource, action })).not.toBe(action);
	});

	it('as opções do filtro são as do recurso', () => {
		const keys = actionOptions('attendance').map((o) => o.key);
		expect(keys).toContain('mark_present');
		expect(keys).not.toContain('cancel');
	});

	// As duas tabelas (verbo curto do filtro × frase do feed) são mantidas à mão, lado a lado.
	// O bate-volta provou o buraco: apagar UMA headline deixava 135 testes verdes, e o efeito em
	// produção era a sidebar oferecendo "Reserva de pacote" enquanto a linha do feed mostrava o
	// átomo cru `set_pkg_hold`. Este teste é a amarração — e não uma terceira lista digitada.
	it.each(['appointment', 'attendance'] as const)(
		'toda ação de %s tem verbo curto E frase de feed',
		(resource) => {
			const semFrase = actionOptions(resource)
				.map((o) => o.key)
				.filter((action) => {
					const headline = entryHeadline({ resource, action, patient: { id: 'p', nome: 'X' } });
					// Sem entrada na tabela de frases, `entryHeadline` cai no átomo cru.
					return headline === action || headline.startsWith(`${action} ·`);
				});

			expect(semFrase).toEqual([]);
		}
	);
});

describe('entryHeadline', () => {
	// O bug que originou o redesenho: o verbo de `attendance` estava na perspectiva do PACIENTE
	// e era renderizado com o ATOR como sujeito — "Fulano entrou na turma · Mariana" afirmava
	// que quem entrou foi o Fulano.
	it('no participante o verbo é do ATOR e o paciente é o objeto', () => {
		const e = entry({ resource: 'attendance', action: 'create', patient: { id: 'p', nome: 'Mariana' } });
		expect(entryHeadline(e)).toBe('Adicionou Mariana ao atendimento');
	});

	// `Attendance` existe também no atendimento individual (`:schedule` recebe `patient_ids` sem
	// olhar se o tipo é grupo), e a versão não carrega o `grupo` para decidir.
	it('não diz "turma" (mentiria na sessão individual)', () => {
		for (const action of ['create', 'remove', 'transition', 'mark_present']) {
			const e = entry({ resource: 'attendance', action, patient: { id: 'p', nome: 'Mariana' } });
			expect(entryHeadline(e)).not.toMatch(/turma/i);
		}
	});

	it('sem paciente resolvido, degrada sem quebrar a frase', () => {
		const e = entry({ resource: 'attendance', action: 'remove', patient: null });
		expect(entryHeadline(e)).toBe('Removeu um paciente do atendimento');
	});

	it('no agendamento a frase é fechada', () => {
		expect(entryHeadline(entry({ action: 'reschedule' }))).toBe('Remarcou o agendamento');
		expect(entryHeadline(entry({ action: 'exclude' }))).toBe('Excluiu o agendamento');
	});
});

describe('entryContext', () => {
	it('junta profissional e horário da sessão', () => {
		expect(entryContext(entry(), TZ)).toBe('Dra. Bea · seg 20/07, 08:00');
	});

	it('sem contexto resolvido, volta vazio (a linha não mostra a segunda linha)', () => {
		expect(entryContext(entry({ professional: null, starts_at: null }), TZ)).toBe('');
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

describe('formatAt / formatTime / formatSession / dayKey / dayHeading (fuso da clínica)', () => {
	it('formata no fuso da clínica, não do processo', () => {
		expect(formatAt('2026-07-20T14:32:00Z', TZ)).toBe('20/07/2026 11:32');
	});

	// A linha do feed mostra só a hora: o carimbo completo dentro de um grupo que JÁ é o dia
	// repetia a data em 50 linhas.
	it('formatTime devolve só a hora local', () => {
		expect(formatTime('2026-07-20T14:32:00Z', TZ)).toBe('11:32');
	});

	it('formatSession leva o dia da semana e sai sem o ponto da abreviação', () => {
		expect(formatSession('2026-07-20T14:00:00Z', TZ)).toBe('seg 20/07, 11:00');
	});

	it('iso inválido volta como veio', () => {
		expect(formatAt('nao-e-data', TZ)).toBe('nao-e-data');
		expect(formatTime('nao-e-data', TZ)).toBe('nao-e-data');
		expect(formatSession('nao-e-data', TZ)).toBe('nao-e-data');
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

	it('dayHeading marca hoje e ontem quando sabe que dia é hoje', () => {
		expect(dayHeading('2026-07-20', '2026-07-20')).toBe('Hoje · segunda-feira, 20 de julho');
		expect(dayHeading('2026-07-19', '2026-07-20')).toBe('Ontem · domingo, 19 de julho');
		expect(dayHeading('2026-07-18', '2026-07-20')).toBe('18 de julho de 2026');
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

describe('estado na URL', () => {
	// A armadilha: manter a ação ao trocar de recurso devolve um feed LEGITIMAMENTE vazio (as
	// tabelas de ação não se cruzam), e isso lê como defeito.
	it('trocar de recurso zera ação, registro e página', () => {
		expect(resourcePatch('attendance')).toEqual({
			resource: 'attendance',
			acao: null,
			record_id: null,
			page: null
		});
		// O default sai da URL, para o link ficar limpo.
		expect(resourcePatch('appointment').resource).toBeNull();
	});

	it('auditHref remenda a query preservando o resto', () => {
		const params = new URLSearchParams('resource=attendance&periodo=7d&page=3');
		expect(auditHref(params, { acao: 'mark_present', page: null })).toBe(
			'/auditoria?resource=attendance&periodo=7d&acao=mark_present'
		);
	});
});

describe('activeChips', () => {
	const base = {
		resource: 'appointment' as const,
		action: null,
		period: 'tudo' as const,
		autor: null,
		recordId: null,
		autores: [{ id: 'u1', nome: 'Ana Gestora' }]
	};

	it('sem filtro, nenhum chip', () => {
		expect(activeChips(base)).toEqual([]);
	});

	it('um chip por eixo ativo, com a chave que o limpa', () => {
		const chips = activeChips({
			...base,
			period: '7d',
			action: 'cancel',
			autor: 'u1',
			recordId: 'a1'
		});

		expect(chips.map((c) => c.key)).toEqual(['periodo', 'acao', 'autor', 'record_id']);
		expect(chips.map((c) => c.label)).toEqual([
			'Últimos 7 dias',
			'Cancelou',
			'Por Ana Gestora',
			'Um registro só'
		]);
	});

	it('autor que não está na equipe não quebra o chip', () => {
		const [chip] = activeChips({ ...base, autor: 'sumiu' });
		expect(chip.label).toBe('Por Autor');
	});
});
