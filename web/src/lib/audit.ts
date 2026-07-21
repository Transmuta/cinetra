// Tipos e regras puras da tela de auditoria (`/configuracoes/auditoria`, doc 25 §11.4). A
// autoridade real é a API (recurso `*.Version` + policies `owner·admin`); aqui é UX — traduzir
// os nomes técnicos para português de clínica, formatar os valores do diff e formatar o "quando"
// no fuso da clínica. Sem essa camada a tela mostraria nome de coluna e uuid para a recepção.
import { canManageMembers, type Papel } from './session';
import { STATUS_META, zonedParts, type AppointmentStatus } from './agenda';

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
	// Contexto do agendamento (null no attendance).
	starts_at: string | null;
	professional: AuditRef | null;
	// Contexto do participante (null no appointment).
	patient: AuditRef | null;
	appointment_id: string | null;
	diff: DiffRow[];
}

export interface AuditPage {
	limit: number;
	offset: number;
	total: number;
	more: boolean;
}

export interface AuditData {
	entries: AuditEntry[];
	page: AuditPage;
}

// Filtro de tipo de recurso da tela (o eixo que troca qual `*.Version` a API pagina).
export type ResourceFilter = 'appointment' | 'attendance';

export function parseResource(value: string | null | undefined): ResourceFilter {
	return value === 'attendance' ? 'attendance' : 'appointment';
}

// Nº da página (1-based) vindo da URL; qualquer coisa inválida é a página 1. Mesmo contrato de
// `patients.parsePage`.
export function parsePage(value: string | null | undefined): number {
	const n = Number(value);
	return Number.isInteger(n) && n > 0 ? n : 1;
}

// Rótulo do rodapé ("1–50 de 214"). Vazio quando não há resultado.
export function pageLabel(page: AuditPage, shown: number): string {
	if (!page.total || !shown) return '';
	return `${page.offset + 1}–${page.offset + shown} de ${page.total}`;
}

// Só owner·admin veem a auditoria (RBAC da API; aqui é o gating do menu/UX). Espelha o
// `with_admin_scope` do controller — a autoridade continua na policy.
export const canViewAudit: (papel: Papel | null | undefined) => boolean = canManageMembers;

// ---- Tradução das ações (§11.4) ----
// Por recurso: a mesma `:create` é "agendou" no appointment e "entrou na turma" no attendance.

const APPOINTMENT_ACTIONS: Record<string, string> = {
	schedule: 'Agendou',
	add_participant: 'Adicionou participante',
	reschedule: 'Remarcou',
	mark_completed: 'Concluiu',
	mark_missed: 'Marcou falta',
	cancel: 'Cancelou',
	reopen: 'Reabriu',
	set_falta_justificada: 'Justificou a falta'
};

const ATTENDANCE_ACTIONS: Record<string, string> = {
	create: 'Entrou na turma',
	transition: 'Mudou a presença',
	destroy: 'Saiu da turma'
};

export function actionLabel(entry: Pick<AuditEntry, 'resource' | 'action'>): string {
	const table = entry.resource === 'attendance' ? ATTENDANCE_ACTIONS : APPOINTMENT_ACTIONS;
	return table[entry.action] ?? entry.action;
}

// ---- Tradução dos campos do diff ----

const FIELD_LABELS: Record<string, string> = {
	status: 'Situação',
	starts_at: 'Início',
	obs: 'Observação',
	encaixe: 'Encaixe',
	duration_minutos: 'Duração',
	cancel_reason: 'Motivo do cancelamento',
	falta_justificada: 'Falta justificada'
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
	if (field === 'starts_at') return formatAt(String(value), timezone);
	if (typeof value === 'boolean') return value ? 'Sim' : 'Não';
	return String(value);
}

// ---- "Quando", no fuso da clínica ----

const atCache = new Map<string, Intl.DateTimeFormat>();

// O instante da mudança formatado no fuso da clínica (ADR-009) — NUNCA no fuso do processo/
// browser, como o resto da agenda (`agenda.ts`). "20/07/2026 14:32".
export function formatAt(iso: string, timezone: string): string {
	const ms = Date.parse(iso);
	if (Number.isNaN(ms)) return iso;

	let fmt = atCache.get(timezone);
	if (!fmt) {
		fmt = new Intl.DateTimeFormat('pt-BR', {
			timeZone: timezone,
			day: '2-digit',
			month: '2-digit',
			year: 'numeric',
			hour: '2-digit',
			minute: '2-digit',
			hour12: false
		});
		atCache.set(timezone, fmt);
	}
	// "20/07/2026, 14:32" → "20/07/2026 14:32" (a vírgula do locale é ruído aqui).
	return fmt.format(new Date(ms)).replace(', ', ' ');
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

// Cabeçalho de um grupo do feed a partir da chave de dia ("2026-07-20" → "20 de julho de 2026").
// Parte da string local (não `new Date`, que a interpretaria em UTC e poderia recuar um dia).
export function dayHeading(key: string): string {
	const [y, m, d] = key.split('-').map(Number);
	if (!y || !m || !d) return key;
	return `${d} de ${MONTHS[m - 1]} de ${y}`;
}

// Agrupa as entradas (já em ordem decrescente) por dia local, preservando a ordem. Cada grupo
// leva a chave e o cabeçalho prontos.
export function groupByDay(
	entries: AuditEntry[],
	timezone: string
): { day: string; heading: string; entries: AuditEntry[] }[] {
	const groups: { day: string; heading: string; entries: AuditEntry[] }[] = [];
	for (const entry of entries) {
		const day = dayKey(entry.at, timezone);
		let last = groups[groups.length - 1];
		if (!last || last.day !== day) {
			last = { day, heading: dayHeading(day), entries: [] };
			groups.push(last);
		}
		last.entries.push(entry);
	}
	return groups;
}
