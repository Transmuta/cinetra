import { describe, it, expect } from 'vitest';
import {
	parseResource,
	type AuditResource,
	RESOURCE_GROUPS,
	resourcesOf,
	resourceParam,
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

// A outra ponta da tripwire de `api/test/api/audit/capture_ligado_test.exs`. O enum do Elixir é a
// autoridade; aqui se afirma que **todo** recurso dele tem lugar numa faceta da sidebar.
//
// Sem isto, o bate-volta mediu o buraco: remover `professional_hours` e `schedule_exception` de
// um grupo deixava os 57 testes verdes — e o efeito em produção era que dois recursos sumiam da
// sidebar e do filtro de ação, sem que o admin tivesse como saber que existem. O teste que se
// anunciava como a amarração (`it.each(RESOURCE_GROUPS…)`) era **auto-referente**: iterando os
// grupos, um recurso que nunca chega a um grupo é invisível a ele.
describe('cobertura dos grupos de registro', () => {
	const TODOS: ReadonlyArray<AuditResource> = [
		'appointment',
		'attendance',
		'patient',
		'professional',
		'membership',
		'clinic',
		'appointment_type',
		'clinic_hours',
		'professional_hours',
		'schedule_exception',
		'package',
		'waitlist_entry',
		'attachment',
		'seguranca'
	];

	it('todo recurso da trilha cai em exatamente um grupo', () => {
		const nos_grupos = RESOURCE_GROUPS.flatMap((g) => g.resources);

		expect([...nos_grupos].sort()).toEqual([...TODOS].sort());
	});

	it('"tudo" (sem grupo) cobre a lista inteira', () => {
		expect([...resourcesOf(null)].sort()).toEqual([...TODOS].sort());
	});
});

// Os NOMES DE AÇÃO que o backend de fato grava em `audit_events.action` — a outra ponta da
// tripwire de `api/test/api/audit/acoes_auditadas_test.exs`, que os deriva do DSL do Ash.
//
// Esta lista é o que faltava, e a falta era um buraco de verdade: as duas tabelas da tela
// (`ACTION_LABELS` e `HEADLINES`) são mantidas à mão a partir da MESMA lista de nomes, então o
// teste que as amarrava uma na outra (`actionOptions` → `entryHeadline`) concordava com qualquer
// nome inventado — bastava inventá-lo nas duas. Medido no banco de dev: `enqueue`, `dequeue`,
// `mark_paused`, `mark_active`, `mark_cancelled` e o `set_pkg_hold` do participante NUNCA
// tiveram tradução, e a tela mostrava a rede genérica ("Criou um registro") sobre a fila inteira
// — enquanto a sidebar oferecia filtros ("Colocou na fila") por nomes que não existem no banco e
// que, por isso, sempre devolviam vazio.
const ACOES_DO_BACKEND: ReadonlyArray<readonly [AuditResource, string]> = (
	[
		['appointment', ['schedule', 'add_participant', 'remove_participant', 'reschedule',
			'set_pkg_hold', 'cancel', 'reopen', 'apply_participant_rollup', 'exclude']],
		['attendance', ['create', 'transition', 'mark_present', 'mark_absent', 'reopen_attendance',
			'justify_absence', 'set_pkg_hold', 'remove']],
		['patient', ['create', 'update', 'deactivate', 'reactivate', 'visualizou_ficha']],
		['professional', ['create', 'update', 'deactivate', 'reactivate']],
		['membership', ['invite', 'invite_by_email', 'update', 'accept_invite', 'revoke_access']],
		['clinic', ['onboard', 'update_settings', 'update_messaging', 'update_info']],
		['appointment_type', ['create', 'update', 'archive', 'restore']],
		['clinic_hours', ['set_day']],
		['professional_hours', ['set_day']],
		['schedule_exception', ['create', 'destroy']],
		[
			'package',
			['create', 'mark_paused', 'mark_active', 'mark_cancelled', 'mark_completed', 'set_total']
		],
		['waitlist_entry', ['enqueue', 'update', 'dequeue']],
		['attachment', ['enviou', 'visualizou', 'renomeou', 'removeu']],
		['seguranca', ['acesso_negado']]
	] as ReadonlyArray<readonly [AuditResource, string[]]>
).flatMap(([resource, acoes]) => acoes.map((action) => [resource, action] as const));

describe('as ações que o backend grava têm tradução', () => {
	it.each(ACOES_DO_BACKEND)('%s/%s tem verbo curto', (resource, action) => {
		expect(actionLabel({ resource, action })).not.toBe(action);
	});

	it.each(ACOES_DO_BACKEND)('%s/%s tem frase de feed', (resource, action) => {
		const headline = entryHeadline({
			resource,
			action,
			action_type: 'update',
			label: 'Registro X',
			patient: { id: 'p', nome: 'Mariana' }
		});

		expect(headline).not.toMatch(/^Alterou um registro/);
	});

	// O outro lado: nome que a tela oferece no filtro e o backend não grava devolve feed VAZIO,
	// que lê como "não aconteceu nada". Ninguém teria como suspeitar do filtro.
	it('e a tela não oferece filtro por ação que não existe', () => {
		const conhecidas = new Set(ACOES_DO_BACKEND.map(([r, a]) => `${r}:${a}`));
		const orfas: string[] = [];

		for (const resource of resourcesOf(null)) {
			for (const { key } of actionOptions(null)) {
				// Só as ações QUE SÃO deste recurso (o `actionOptions(null)` reúne todos).
				if (actionLabel({ resource, action: key }) === key) continue;
				if (!conhecidas.has(`${resource}:${key}`)) orfas.push(`${resource}/${key}`);
			}
		}

		// As APOSENTADAS são a exceção legítima: a trilha guarda o que aconteceu, e linhas antigas
		// carregam nomes de ações que o código não tem mais. Sem o rótulo elas voltariam a exibir
		// o átomo cru — por isso ficam nas tabelas, e por isso são nomeadas aqui uma a uma.
		const aposentadas = [
			'appointment/mark_completed',
			'appointment/mark_missed',
			'appointment/set_falta_justificada',
			'attendance/set_package'
		];

		expect(orfas.filter((o) => !aposentadas.includes(o))).toEqual([]);
	});
});

describe('parseResource / parsePage', () => {
	it('resource cai em appointment para qualquer valor que não seja attendance', () => {
		expect(parseResource('agenda')).toBe('agenda');
		expect(parseResource('cadastros')).toBe('cadastros');
		// "Tudo" (null) é o DEFAULT: sem grupo o feed é da clínica inteira (doc 63). Era o
		// contrário — `appointment` era o default e não havia como pedir "tudo".
		expect(parseResource(null)).toBeNull();
		expect(parseResource('lixo')).toBeNull();
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
		expect(parseAction('cancel', 'agenda')).toBe('cancel');
		expect(parseAction('mark_present', 'agenda')).toBe('mark_present');
		expect(parseAction('deactivate', 'cadastros')).toBe('deactivate');
	});

	// Sem esta validação a tela mostraria o chip "Cancelou" sobre um recorte que não corresponde
	// ao grupo aberto. Do lado da API isso deixou de devolver o feed inteiro (doc 63: `action` é
	// coluna de texto, nome desconhecido devolve vazio) — mas o chip mentiroso continuaria.
	it('recusa a ação de OUTRO grupo e o lixo', () => {
		expect(parseAction('cancel', 'anexos')).toBeNull();
		expect(parseAction('mark_present', 'cadastros')).toBeNull();
		expect(parseAction('nao_existe', 'agenda')).toBeNull();
		expect(parseAction(null, 'agenda')).toBeNull();
		expect(parseAction('', 'agenda')).toBeNull();
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

	// O rollup do desfecho roda em TODO bloco — de um paciente ou de turma. Falar em "turma"
	// fazia o atendimento individual exibir "Atualizou a situação pela turma", que é falso.
	it('o rollup não inventa turma onde há um paciente só', () => {
		const e = { resource: 'appointment', action: 'apply_participant_rollup' } as const;
		expect(actionLabel(e)).not.toMatch(/turma/i);
		expect(entryHeadline({ ...e, action_type: 'update', patient: null, label: null })).not.toMatch(
			/turma/i
		);
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

	it('as opções do filtro são as do grupo', () => {
		const agenda = actionOptions('agenda').map((o) => o.key);
		expect(agenda).toContain('mark_present');
		expect(agenda).toContain('cancel');

		const anexos = actionOptions('anexos').map((o) => o.key);
		expect(anexos).toContain('visualizou');
		expect(anexos).not.toContain('cancel');
	});

	// Sem grupo, o filtro oferece as ações de TODOS os recursos — é o feed da clínica inteira,
	// que passou a ser o default (doc 63).
	it('sem grupo, oferece as ações de todos os recursos', () => {
		const keys = actionOptions(null).map((o) => o.key);
		expect(keys).toContain('cancel');
		expect(keys).toContain('visualizou_ficha');
		expect(keys).toContain('revoke_access');
	});

	// As duas tabelas (verbo curto do filtro × frase do feed) são mantidas à mão, lado a lado.
	// O bate-volta provou o buraco: apagar UMA headline deixava 135 testes verdes, e o efeito em
	// produção era a sidebar oferecendo "Reserva de pacote" enquanto a linha do feed mostrava o
	// átomo cru `set_pkg_hold`. Este teste é a amarração — e não uma terceira lista digitada.
	//
	// Agora varre os TREZE recursos, não os dois de antes: cada um que entra na trilha precisa
	// das duas entradas, e é aqui que "liguei a trilha e esqueci de traduzir" fica vermelho.
	it.each(RESOURCE_GROUPS.map((g) => g.key))(
		'toda ação do grupo %s tem verbo curto E frase de feed',
		(group) => {
			const semFrase: string[] = [];

			for (const resource of resourcesOf(group)) {
				for (const { key: action } of actionOptions(group)) {
					// Só as ações QUE SÃO deste recurso (o grupo pode reunir vários).
					if (actionLabel({ resource, action }) === action) continue;

					const headline = entryHeadline({
						resource,
						action,
						action_type: 'update',
						label: 'X',
						patient: { id: 'p', nome: 'X' }
					});

					// Sem entrada na tabela de frases, `entryHeadline` cai no verbo genérico do tipo.
					if (headline.startsWith('Alterou um registro')) semFrase.push(`${resource}/${action}`);
				}
			}

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

	// A rede é o último recurso, mas ela também é uma LINHA DE AUDITORIA: tem de dizer o quê.
	// "Criou um registro", sozinho, foi o que a tela mostrou para a fila de espera inteira.
	describe('a rede (ação que a tela não conhece)', () => {
		const desconhecida = (over = {}) =>
			entry({ resource: 'waitlist_entry', action: 'acao_nova', action_type: 'create', ...over });

		it('diz o TIPO do registro', () => {
			expect(entryHeadline(desconhecida())).toBe('Criou um registro de fila de espera');
		});

		it('e o nome do registro quando a linha tem um', () => {
			const e = desconhecida({ patient: { id: 'p', nome: 'Mariana' } });
			expect(entryHeadline(e)).toBe('Criou um registro de fila de espera — Mariana');
		});

		it('o `label` gravado vence o paciente (é o nome do próprio registro)', () => {
			const e = desconhecida({ label: 'Pacote 10 sessões', patient: { id: 'p', nome: 'Mariana' } });
			expect(entryHeadline(e)).toBe('Criou um registro de fila de espera — Pacote 10 sessões');
		});

		it('o acesso negado não vira "negado de segurança"', () => {
			const e = entry({ resource: 'seguranca', action: 'nova', action_type: 'deny', label: null });
			expect(entryHeadline(e)).toBe('Acesso negado em segurança');
		});
	});
});

describe('entryContext', () => {
	it('junta profissional e horário da sessão', () => {
		expect(entryContext(entry(), TZ)).toBe('Dra. Bea · seg 20/07, 08:00');
	});

	it('sem contexto resolvido, volta vazio (a linha não mostra a segunda linha)', () => {
		expect(entryContext(entry({ professional: null, meta: {} }), TZ)).toBe('');
	});

	// O buraco que fazia o feed da agenda ser ilegível: num dia de trabalho todas as linhas são
	// do mesmo profissional, e sem o paciente uma não se distingue da seguinte.
	it('o QUEM vem primeiro nas linhas de agendamento', () => {
		const e = entry({ participants: [{ id: 'x', nome: 'Caio Paciente' }] });
		expect(entryContext(e, TZ)).toBe('Caio Paciente · Dra. Bea · seg 20/07, 08:00');
	});

	it('turma: dois nomes e a conta do resto', () => {
		const nomes = ['Ana', 'Caio', 'Duda', 'Edu'].map((nome, i) => ({ id: `p${i}`, nome }));
		expect(entryContext(entry({ participants: nomes }), TZ)).toBe(
			'Ana, Caio e mais 2 · Dra. Bea · seg 20/07, 08:00'
		);
	});

	// Em "Marcou a falta de Caio" o nome dele de novo logo abaixo é ruído, não contexto.
	it('o paciente não se repete quando a própria frase já o nomeia', () => {
		const e = entry({
			resource: 'attendance',
			action: 'mark_absent',
			patient: { id: 'x', nome: 'Caio Paciente' },
			meta: { session_starts_at: '2026-07-20T11:00:00Z' }
		});
		expect(entryContext(e, TZ)).toBe('Dra. Bea · seg 20/07, 08:00');
	});

	it('mas aparece quando a frase fala do registro, não do paciente', () => {
		const e = entry({
			resource: 'package',
			action: 'mark_paused',
			label: 'Pacote 10',
			patient: { id: 'x', nome: 'Caio Paciente' },
			professional: null,
			meta: {}
		});
		expect(entryContext(e, TZ)).toBe('Caio Paciente');
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
	it('trocar de grupo zera ação, registro e página', () => {
		expect(resourcePatch('agenda')).toEqual({
			resource: 'agenda',
			acao: null,
			record_id: null,
			page: null
		});
		// "Tudo" é o default e sai da URL, para o link ficar limpo.
		expect(resourcePatch(null).resource).toBeNull();
	});

	it('auditHref remenda a query preservando o resto', () => {
		const params = new URLSearchParams('resource=agenda&periodo=7d&page=3');
		expect(auditHref(params, { acao: 'mark_present', page: null })).toBe(
			'/auditoria?resource=agenda&periodo=7d&acao=mark_present'
		);
	});
});

describe('activeChips', () => {
	const base = {
		resource: null,
		action: null,
		period: 'tudo' as const,
		autor: null,
		recordId: null,
		autores: [{ id: 'u1', nome: 'Ana Gestora' }]
	};

	it('sem filtro, nenhum chip', () => {
		expect(activeChips(base)).toEqual([]);
	});

	it('um chip por eixo ativo, na ordem da sidebar, com a chave que o limpa', () => {
		const chips = activeChips({
			...base,
			period: '7d',
			action: 'cancel',
			autor: 'u1',
			recordId: 'a1'
		});

		expect(chips.map((c) => c.key)).toEqual(['periodo', 'autor', 'acao', 'record_id']);
		expect(chips.map((c) => c.label)).toEqual([
			'Últimos 7 dias',
			'Por Ana Gestora',
			'Cancelou',
			'Um registro só'
		]);
	});

	it('autor que não está na equipe não quebra o chip', () => {
		const [chip] = activeChips({ ...base, autor: 'sumiu' });
		expect(chip.label).toBe('Por Autor');
	});
});
