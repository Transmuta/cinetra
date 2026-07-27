// Tipos e regras puras da tela de auditoria (`/auditoria`, doc 25 §11.4). A autoridade real é a
// API (recurso `*.Version` + policies `owner·admin`); aqui é UX — traduzir os nomes técnicos para
// português de clínica, formatar os valores do diff e formatar o "quando" no fuso da clínica.
// Sem essa camada a tela mostraria nome de coluna e uuid para a recepção.
import { canManageMembers, type Papel } from './session';
import { STATUS_META, shiftDate, zonedParts, type AppointmentStatus } from './agenda';
import { hrefWithQuery, type QueryPatch } from './querystring';
import { parsePage, type PageInfo } from './pagination';

// `parsePage` e a forma do recorte vêm de `$lib/pagination` — a fonte única declarada ("o pouco
// que toda tela paginada repete"). Esta tela chegou a ter uma **segunda cópia** de `parsePage`,
// idêntica byte a byte, e o bate-volta mediu o preço: sabotar a do módulo central deixava os 59
// testes da Auditoria verdes. Duas implementações que ninguém sabia estarem desligadas.
export { parsePage };

export type AuditResource = 'appointment' | 'attendance';

export interface AuditRef {
	id: string;
	nome: string;
}

// Uma linha do diff campo-a-campo. `from`/`to` são os valores JÁ "dumpados" pela trilha
// (string/número/booleano/null) — o backend monta o par encadeando as versões (:changes_only).
export interface DiffRow {
	field: string;
	from: unknown;
	to: unknown;
}

export interface AuditEntry {
	id: string;
	resource: AuditResource;
	record_id: string;
	action: string;
	action_type: 'create' | 'update' | 'destroy';
	// ISO-8601 UTC de QUANDO a mudança foi gravada.
	at: string;
	status: string | null;
	actor: AuditRef | null;
	// Contexto do BLOCO: no participante os dois vêm do agendamento, enriquecidos pela API.
	starts_at: string | null;
	professional: AuditRef | null;
	// Contexto do participante (null no appointment).
	patient: AuditRef | null;
	appointment_id: string | null;
	diff: DiffRow[];
}

export interface AuditData {
	entries: AuditEntry[];
	// `PageInfo` do módulo de paginação: o `total` dele já é **opcional**, exatamente pelo motivo
	// do D-Aud1 (a trilha não paga `COUNT(*)`), então não havia por que declarar uma forma própria.
	page: PageInfo;
}

/** A rota da tela. Saiu de `/configuracoes/auditoria` — auditar não é um ajuste da clínica. */
export const AUDIT_BASE = '/auditoria';

// Filtro de tipo de recurso da tela (o eixo que troca qual `*.Version` a API pagina).
export type ResourceFilter = AuditResource;

export function parseResource(value: string | null | undefined): ResourceFilter {
	return value === 'attendance' ? 'attendance' : 'appointment';
}

// ---- Período ----
//
// Preset, e não date-picker, por uma razão do servidor: a janela `from`/`to` é validada em
// **menos de 31 dias** (`TenantScope.validate_window`), a mesma regra da agenda. "30 dias" é o
// maior recorte legal; "tudo" é a ausência de janela — que além de ser o default é o caminho
// mais barato (o índice `(clinic_id, version_inserted_at DESC)` já limita o que se lê).

export type PeriodFilter = 'hoje' | '7d' | '30d' | 'tudo';

export const PERIOD_OPTIONS: ReadonlyArray<{ key: PeriodFilter; label: string }> = [
	{ key: 'hoje', label: 'Hoje' },
	{ key: '7d', label: 'Últimos 7 dias' },
	{ key: '30d', label: 'Últimos 30 dias' },
	{ key: 'tudo', label: 'Todo o histórico' }
];

export function parsePeriod(value: string | null | undefined): PeriodFilter {
	return value === 'hoje' || value === '7d' || value === '30d' ? value : 'tudo';
}

/**
 * A janela `from`/`to` (datas locais da clínica) de um preset, ou `null` para "tudo".
 *
 * `hoje` é a data local **do servidor** — nunca `new Date()` no browser (ADR-009).
 */
export function periodRange(
	period: PeriodFilter,
	hoje: string
): { from: string; to: string } | null {
	if (period === 'hoje') return { from: hoje, to: hoje };
	if (period === '7d') return { from: shiftDate(hoje, -6), to: hoje };
	if (period === '30d') return { from: shiftDate(hoje, -29), to: hoje };
	return null;
}

// ---- Tradução das ações (§11.4) ----
//
// Duas tabelas por recurso, porque são dois usos diferentes:
//
//   * `ACTION_LABELS` — o verbo curto, para o filtro e para o chip ("Remarcou");
//   * `HEADLINES` — a frase da linha do feed, com o objeto no lugar certo.
//
// A frase importa mais do que parece. Os verbos de `attendance` nasceram na perspectiva do
// PACIENTE ("Entrou na turma") e eram renderizados com o ATOR como sujeito — o feed dizia
// literalmente "Fulano entrou na turma · Mariana", afirmando algo falso. Aqui todo verbo é de
// ator, e o paciente entra como objeto da própria frase.
//
// "Turma" também saiu: `Attendance` existe para todo participante, inclusive o de atendimento
// individual (`:schedule` recebe `patient_ids` sem olhar se o tipo é grupo), e a versão não
// carrega o `grupo` do tipo para decidir. "Atendimento" é verdadeiro nos dois casos.

const APPOINTMENT_ACTION_LABELS: Record<string, string> = {
	schedule: 'Agendou',
	add_participant: 'Adicionou participante',
	remove_participant: 'Removeu participante',
	reschedule: 'Remarcou',
	cancel: 'Cancelou',
	reopen: 'Reabriu',
	exclude: 'Excluiu',
	apply_participant_rollup: 'Atualizou pela turma',
	set_pkg_hold: 'Reserva de pacote',
	// As três abaixo são de ações **aposentadas** (o eixo de bloco saiu na A2/bate-volta da
	// Onda 3). Ficam porque a trilha guarda o que aconteceu: linhas antigas de
	// `appointments_versions` carregam esses nomes, e sem o rótulo a tela mostraria o átomo cru.
	mark_completed: 'Concluiu',
	mark_missed: 'Marcou falta',
	set_falta_justificada: 'Justificou a falta'
};

const ATTENDANCE_ACTION_LABELS: Record<string, string> = {
	create: 'Adicionou ao atendimento',
	remove: 'Removeu do atendimento',
	transition: 'Alterou a presença',
	mark_present: 'Marcou presença',
	mark_absent: 'Marcou falta',
	reopen_attendance: 'Reabriu a presença',
	justify_absence: 'Justificou a falta',
	set_package: 'Vinculou a um pacote'
};

const APPOINTMENT_HEADLINES: Record<string, string> = {
	schedule: 'Criou o agendamento',
	add_participant: 'Adicionou um participante',
	remove_participant: 'Removeu um participante',
	reschedule: 'Remarcou o agendamento',
	cancel: 'Cancelou o agendamento',
	reopen: 'Reabriu o agendamento',
	exclude: 'Excluiu o agendamento',
	apply_participant_rollup: 'Atualizou a situação pela turma',
	set_pkg_hold: 'Atualizou a reserva do pacote',
	mark_completed: 'Concluiu o agendamento',
	mark_missed: 'Marcou falta no agendamento',
	set_falta_justificada: 'Justificou a falta'
};

// `{p}` é o nome do paciente. Sem paciente resolvido (registro apagado), vira "um paciente".
const ATTENDANCE_HEADLINES: Record<string, string> = {
	create: 'Adicionou {p} ao atendimento',
	remove: 'Removeu {p} do atendimento',
	transition: 'Alterou a presença de {p}',
	mark_present: 'Marcou a presença de {p}',
	mark_absent: 'Marcou a falta de {p}',
	reopen_attendance: 'Reabriu a presença de {p}',
	justify_absence: 'Justificou a falta de {p}',
	set_package: 'Vinculou a sessão de {p} a um pacote'
};

function labelTable(resource: AuditResource): Record<string, string> {
	return resource === 'attendance' ? ATTENDANCE_ACTION_LABELS : APPOINTMENT_ACTION_LABELS;
}

/** O verbo curto da ação — filtro, chip. Ação desconhecida cai no nome cru (não quebra). */
export function actionLabel(entry: Pick<AuditEntry, 'resource' | 'action'>): string {
	return labelTable(entry.resource)[entry.action] ?? entry.action;
}

/** As ações filtráveis de um recurso, na ordem em que a sidebar as mostra. */
export function actionOptions(
	resource: AuditResource
): ReadonlyArray<{ key: string; label: string }> {
	return Object.entries(labelTable(resource)).map(([key, label]) => ({ key, label }));
}

/**
 * A ação vinda da URL, **validada contra o recurso**.
 *
 * Nome fora da tabela vira `null` (sem filtro). Isso não é preciosismo: a whitelist da API
 * também devolve filtro nulo para nome desconhecido — o feed inteiro volta e quem filtrou não
 * percebe. Validar dos dois lados é o que impede a tela de exibir um chip "Cancelou" sobre uma
 * lista que não está filtrada.
 */
export function parseAction(
	value: string | null | undefined,
	resource: AuditResource
): string | null {
	if (!value) return null;
	return value in labelTable(resource) ? value : null;
}

/**
 * A frase da linha do feed: verbo de ator + objeto. O ator NÃO entra aqui — ele vai para a
 * terceira linha ("por Fulano"), onde não compete com o fato.
 */
export function entryHeadline(entry: Pick<AuditEntry, 'resource' | 'action' | 'patient'>): string {
	if (entry.resource === 'attendance') {
		const nome = entry.patient?.nome ?? 'um paciente';
		const template = ATTENDANCE_HEADLINES[entry.action];
		return template ? template.replace('{p}', nome) : `${entry.action} · ${nome}`;
	}
	return APPOINTMENT_HEADLINES[entry.action] ?? entry.action;
}

/** O contexto do bloco: "Dra. Bea · ter 20/07, 09:00". Vazio quando nada foi resolvido. */
export function entryContext(
	entry: Pick<AuditEntry, 'professional' | 'starts_at'>,
	timezone: string
): string {
	const partes = [
		entry.professional?.nome,
		entry.starts_at ? formatSession(entry.starts_at, timezone) : null
	].filter(Boolean);
	return partes.join(' · ');
}

// ---- Tradução dos campos do diff ----

const FIELD_LABELS: Record<string, string> = {
	status: 'Situação',
	starts_at: 'Início',
	obs: 'Observação',
	encaixe: 'Encaixe',
	duration_minutos: 'Duração',
	cancel_reason: 'Motivo do cancelamento',
	falta_justificada: 'Falta justificada',
	excluded_at: 'Excluído em',
	justificativa: 'Justificativa'
};

export function fieldLabel(field: string): string {
	return FIELD_LABELS[field] ?? field;
}

// Situação do participante (o `AttendanceStatus` da API). A do agendamento reusa `STATUS_META`
// da agenda — fonte única, para o mesmo "Concluído" não divergir entre a agenda e a auditoria.
const ATTENDANCE_STATUS_LABELS: Record<string, string> = {
	prevista: 'Prevista',
	concluida: 'Concluída',
	faltou: 'Faltou',
	cancelada: 'Cancelada'
};

function statusLabel(resource: AuditResource, value: string): string {
	if (resource === 'attendance') return ATTENDANCE_STATUS_LABELS[value] ?? value;
	return STATUS_META[value as AppointmentStatus]?.label ?? value;
}

// Formata um VALOR do diff para exibição, ciente do campo e do recurso: datas → hora local da
// clínica; situação → rótulo; booleano → Sim/Não; nulo/vazio → "—".
export function formatValue(
	resource: AuditResource,
	field: string,
	value: unknown,
	timezone: string
): string {
	if (value === null || value === undefined || value === '') return '—';
	if (field === 'status') return statusLabel(resource, String(value));
	if (field === 'starts_at' || field === 'excluded_at') return formatAt(String(value), timezone);
	if (typeof value === 'boolean') return value ? 'Sim' : 'Não';
	return String(value);
}

// ---- "Quando", no fuso da clínica ----

const atCache = new Map<string, Intl.DateTimeFormat>();
const timeCache = new Map<string, Intl.DateTimeFormat>();
const sessionCache = new Map<string, Intl.DateTimeFormat>();

function cached(
	cache: Map<string, Intl.DateTimeFormat>,
	timezone: string,
	options: Intl.DateTimeFormatOptions
): Intl.DateTimeFormat {
	let fmt = cache.get(timezone);
	if (!fmt) {
		fmt = new Intl.DateTimeFormat('pt-BR', { timeZone: timezone, hour12: false, ...options });
		cache.set(timezone, fmt);
	}
	return fmt;
}

// O instante da mudança formatado no fuso da clínica (ADR-009) — NUNCA no fuso do processo/
// browser, como o resto da agenda (`agenda.ts`). "20/07/2026 14:32". Segue sendo o carimbo
// COMPLETO: é o que vai no `title` da linha (o corpo mostra só a hora, dentro do grupo do dia).
export function formatAt(iso: string, timezone: string): string {
	const ms = Date.parse(iso);
	if (Number.isNaN(ms)) return iso;

	const fmt = cached(atCache, timezone, {
		day: '2-digit',
		month: '2-digit',
		year: 'numeric',
		hour: '2-digit',
		minute: '2-digit'
	});
	// "20/07/2026, 14:32" → "20/07/2026 14:32" (a vírgula do locale é ruído aqui).
	return fmt.format(new Date(ms)).replace(', ', ' ');
}

/** Só a hora ("14:32") — o que a linha mostra, já que o grupo diz o dia. */
export function formatTime(iso: string, timezone: string): string {
	const ms = Date.parse(iso);
	if (Number.isNaN(ms)) return iso;
	return cached(timeCache, timezone, { hour: '2-digit', minute: '2-digit' }).format(new Date(ms));
}

/** O horário da SESSÃO, para a linha de contexto: "ter 20/07, 09:00". */
export function formatSession(iso: string, timezone: string): string {
	const ms = Date.parse(iso);
	if (Number.isNaN(ms)) return iso;

	const fmt = cached(sessionCache, timezone, {
		weekday: 'short',
		day: '2-digit',
		month: '2-digit',
		hour: '2-digit',
		minute: '2-digit'
	});
	// pt-BR devolve "seg., 20/07, 09:00" (ou "seg, …" conforme o ICU) — o ponto e a vírgula da
	// abreviação são ruído numa linha densa. O recorte é `[^,]` e não `\w` porque "sáb" tem
	// acento, que `\w` não casa.
	return fmt.format(new Date(ms)).replace(/^([^,]+?)\.?,\s*/, '$1 ');
}

// Dia local (chave de agrupamento do feed por data). "2026-07-20". Reusa `zonedParts` da agenda
// — fonte única do "dia local de um instante" — que já cacheia o `Intl.DateTimeFormat` por fuso
// (senão `groupByDay` alocaria um formatter por entrada, por render). Guarda o iso inválido.
export function dayKey(iso: string, timezone: string): string {
	if (Number.isNaN(Date.parse(iso))) return iso;
	return zonedParts(iso, timezone).date;
}

const MONTHS = [
	'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho',
	'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'
];

const WEEKDAY_FMT = new Intl.DateTimeFormat('pt-BR', { weekday: 'long', timeZone: 'UTC' });

/**
 * Cabeçalho de um grupo do feed. "20 de julho de 2026" — com **"Hoje ·"** / **"Ontem ·"** e o
 * dia da semana quando o dia é recente, que é o recorte que alguém varre de fato.
 *
 * `hoje` vem do servidor (nunca do relógio do browser). Sem ele, degrada para a data seca.
 */
export function dayHeading(key: string, hoje?: string): string {
	const [y, m, d] = key.split('-').map(Number);
	if (!y || !m || !d) return key;

	const data = `${d} de ${MONTHS[m - 1]} de ${y}`;
	if (!hoje) return data;
	if (key === hoje) return `Hoje · ${semana(key)}, ${d} de ${MONTHS[m - 1]}`;
	if (key === shiftDate(hoje, -1)) return `Ontem · ${semana(key)}, ${d} de ${MONTHS[m - 1]}`;
	return data;
}

// Meio-dia UTC de propósito: a data "YYYY-MM-DD" é um dia de calendário, e ler às 00:00 faria
// qualquer fuso a oeste recuar um dia no nome da semana.
function semana(key: string): string {
	return WEEKDAY_FMT.format(new Date(`${key}T12:00:00Z`));
}

// Agrupa as entradas (já em ordem decrescente) por dia local, preservando a ordem. Cada grupo
// leva a chave e o cabeçalho prontos.
export function groupByDay(
	entries: AuditEntry[],
	timezone: string,
	hoje?: string
): { day: string; heading: string; entries: AuditEntry[] }[] {
	const groups: { day: string; heading: string; entries: AuditEntry[] }[] = [];
	for (const entry of entries) {
		const day = dayKey(entry.at, timezone);
		let last = groups[groups.length - 1];
		if (!last || last.day !== day) {
			last = { day, heading: dayHeading(day, hoje), entries: [] };
			groups.push(last);
		}
		last.entries.push(entry);
	}
	return groups;
}

/**
 * Rodapé da paginação ("Página 2 · 51–100"). Vazio quando não há resultado.
 *
 * **Sem o "de Z" (D-Aud1).** A trilha é a tabela que mais cresce do projeto, e o total custava um
 * `COUNT(*) OVER ()` por request — que lê o recorte inteiro da clínica apesar do `LIMIT` (medido:
 * 10.265 buffers contra 26 na caixa de notificações, doc 44 §2). Quem olha a auditoria quer
 * *o que aconteceu*, não quantas versões a clínica acumulou; o "tem mais" continua vindo do
 * servidor, exato, e é ele que habilita a seta.
 *
 * Pacientes e Fila **mantêm** o total: aquelas listas têm teto natural e o número responde uma
 * pergunta que alguém de fato faz.
 *
 * Nome próprio (`auditPageLabel`) de propósito: chamar-se `pageLabel` como o do
 * `$lib/pagination` — com **assinatura diferente**, um usando `total` e o outro ignorando-o —
 * é o tipo de colisão que passa despercebida num import trocado.
 */
export function auditPageLabel(page: PageInfo, shown: number, current = 1): string {
	if (!shown) return '';
	const faixa = `${page.offset + 1}–${page.offset + shown}`;
	return current > 1 ? `Página ${current} · ${faixa}` : faixa;
}

// Só owner·admin veem a auditoria (RBAC da API; aqui é o gating do menu/UX). Espelha o
// `with_admin_scope` do controller — a autoridade continua na policy.
export const canViewAudit: (papel: Papel | null | undefined) => boolean = canManageMembers;

// ---- Estado da tela na URL ----

/** Um link da tela com a query remendada (o estado mora na URL, como nas outras listas). */
export function auditHref(params: URLSearchParams, patch: QueryPatch): string {
	return hrefWithQuery(AUDIT_BASE, params, patch);
}

/**
 * O patch que troca de recurso.
 *
 * Zera `acao` e `record_id` junto — e não só a página. As duas tabelas de ação não se cruzam
 * (`cancel` não existe em participante), então manter o filtro ao trocar de aba devolveria um
 * feed **legitimamente** vazio, que lê como defeito. O registro é da mesma forma de um recurso só.
 */
export function resourcePatch(resource: ResourceFilter): QueryPatch {
	return {
		resource: resource === 'appointment' ? null : resource,
		acao: null,
		record_id: null,
		page: null
	};
}

export interface FilterChip {
	/** A chave da query a limpar. */
	key: string;
	label: string;
}

/**
 * Os chips do que está filtrando agora, para o corpo da tela.
 *
 * Filtro que mora na sidebar precisa de eco no corpo: sem isso, uma lista curta (ou vazia) lê
 * como "não aconteceu nada" em vez de "você está filtrando" — o mesmo motivo do vazio ciente
 * do filtro na caixa de notificações (doc 53).
 */
export function activeChips(state: {
	resource: AuditResource;
	action: string | null;
	period: PeriodFilter;
	autor: string | null;
	recordId: string | null;
	autores: AuditRef[];
}): FilterChip[] {
	const chips: FilterChip[] = [];

	if (state.period !== 'tudo') {
		const label = PERIOD_OPTIONS.find((p) => p.key === state.period)?.label ?? state.period;
		chips.push({ key: 'periodo', label });
	}

	if (state.action) {
		chips.push({
			key: 'acao',
			label: actionLabel({ resource: state.resource, action: state.action })
		});
	}

	if (state.autor) {
		const nome = state.autores.find((a) => a.id === state.autor)?.nome ?? 'Autor';
		chips.push({ key: 'autor', label: `Por ${nome}` });
	}

	if (state.recordId) chips.push({ key: 'record_id', label: 'Um registro só' });

	return chips;
}
