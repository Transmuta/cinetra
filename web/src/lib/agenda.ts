// Tipos e regras puras da Agenda (doc 25). Espelha os helpers do protótipo
// (`statusMeta` :810, `m2t`/`t2m` :807, `needsAction` :828, `dayPeriods` :854).
//
// A autoridade real é o servidor: disponibilidade, conflito e permissão são decididos lá
// (doc 25 §3, "o cliente antecipa por ergonomia; o veredito é do servidor"). O que mora aqui
// é o que a TELA precisa para desenhar e para antecipar — nada que só exista no cliente vira
// invariante de negócio.
//
// Sem Svelte e sem DOM: tudo testável no projeto `server` do Vitest.

import type { Papel } from './session';
import { timeToMinutes } from './scheduling';
import type { Period } from './scheduling';
import type { Interval } from './agenda-layout';
import type { AppointmentType } from './appointment-types';

// O tipo de atendimento COMO A AGENDA o recebe. `appointments_controller.ex:render_type`
// manda menos campos que a tela de catálogo: não vêm `sigla` nem `ativo` (o endpoint já
// filtra `ativo: true` no servidor). Reusar o `AppointmentType` cheio aqui prometeria
// campos que chegam `undefined` — e foi exatamente assim que um filtro `t.ativo` no
// cliente esvaziou o seletor de tipos.
export type AgendaAppointmentType = Pick<
	AppointmentType,
	'id' | 'nome' | 'duracao_minutos' | 'cor' | 'icon' | 'grupo' | 'capacidade'
>;

// ---------------------------------------------------------------------------
// Wire (contrato do doc 25 §5)
// ---------------------------------------------------------------------------

export type AppointmentStatus =
	| 'agendado'
	| 'confirmado'
	| 'em_atendimento'
	| 'concluido'
	| 'faltou'
	| 'cancelado';

export interface Appointment {
	id: string;
	/** ISO em UTC — a grade converte para o fuso da clínica antes de desenhar. */
	starts_at: string;
	ends_at: string;
	status: AppointmentStatus;
	encaixe: boolean;
	obs: string | null;
	/** Entrega 4: motivo do cancelamento (opcional, D4). */
	cancel_reason: string | null;
	professional_id: string;
	appointment_type_id: string;
	/** Gancho da Fatia 3 (pacotes); nesta fatia só desenha a tarja lateral. */
	package_id: string | null;
	version: number;
	created_by_id: string | null;
	patient_ids: string[];
	/**
	 * A presença de cada participante (A2, doc 41). `patient_ids` continua sendo o que a grade
	 * usa para o N/cap; isto é o que o drawer marca linha a linha — numa turma de quatro, um pode
	 * ter concluído e outro faltado, e o status do bloco é o **rollup** disso.
	 */
	participants: Participant[];
}

/** O status de UMA presença (`Api.Scheduling.AttendanceStatus`). */
export type AttendanceStatus = 'prevista' | 'concluida' | 'faltou' | 'cancelada';

export interface Participant {
	patient_id: string;
	status: AttendanceStatus;
	falta_justificada: boolean;
	package_id: string | null;
}

/** O profissional como a agenda o consome (subconjunto do diretório). */
export interface AgendaProfessional {
	id: string;
	nome: string;
	nome_exibicao: string | null;
	crefito: string | null;
	cor_indice: number;
	segue_horario_clinica: boolean;
}

export type ClosedReason =
	| 'clinica_fechada'
	| 'folga_profissional'
	| 'clinica_fechada_excecao'
	| 'folga_semanal'
	| 'sem_grade';

export interface AvailabilityDay {
	date: string;
	periods: Period[];
	closed_reason?: ClosedReason;
}

export interface AgendaPatient {
	id: string;
	nome: string;
	tel: string | null;
	/**
	 * Vem `false` para paciente arquivado — e ele APARECE no sidecar de propósito: quem tem
	 * sessão marcada precisa de nome no bloco de qualquer jeito. Nunca filtrar a exibição
	 * por este campo (é o mesmo erro que esvaziou o seletor de tipos de atendimento).
	 * Opcional porque o endpoint de busca do picker não o manda.
	 */
	ativo?: boolean;
	/** Só o endpoint de busca do picker manda (para a cor do avatar); o sidecar não. */
	cor_indice?: number;
	/** Entrega 4: faltas do paciente (agregado). Só o sidecar do GET manda; o picker não. */
	faltas?: number;
}

// id → nome, para o bloco resolver quem é o paciente. Função pura e testada, e não uma
// linha solta no `+page.svelte`, justamente porque é aqui que mora a regra "não filtrar por
// `ativo`" — e página `.svelte` fica fora do gate de cobertura.
export function patientNameMap(patients: AgendaPatient[] | undefined): Record<string, string> {
	return Object.fromEntries((patients ?? []).map((p) => [p.id, p.nome]));
}

/** Retorno da busca do `PatientPicker` (endpoint `/agenda/pacientes`). */
export interface SearchResult {
	patients: AgendaPatient[];
	/** Total no cadastro, para o aviso "Mostrando 10 de N — refine a busca". */
	total: number;
}

/** Um dia de expediente JÁ associado à coluna que o desenha. */
export interface ColumnAvailability extends AvailabilityDay {
	professional_id: string;
}

// ---------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------

export interface StatusMeta {
	label: string;
	/**
	 * Token de cor do design system (`--color-*`), ou null quando o status não pinta o
	 * fundo. Guardamos o NOME do token e não um hex porque o tema claro/escuro troca o
	 * valor em runtime — um hex congelado aqui quebraria o modo escuro.
	 */
	tone: 'info' | 'teal' | 'success' | 'danger' | null;
	/** Concluído a 72% de opacidade (protótipo :1672). */
	dim?: boolean;
	/** Cancelado sai riscado. */
	strike?: boolean;
	/** Em atendimento ganha o ponto pulsante. */
	live?: boolean;
}

export const STATUS_ORDER: readonly AppointmentStatus[] = [
	'agendado',
	'confirmado',
	'em_atendimento',
	'concluido',
	'faltou',
	'cancelado'
] as const;

export const STATUS_META: Record<AppointmentStatus, StatusMeta> = {
	agendado: { label: 'Agendado', tone: null },
	confirmado: { label: 'Confirmado', tone: 'info' },
	em_atendimento: { label: 'Em atendimento', tone: 'teal', live: true },
	concluido: { label: 'Concluído', tone: 'success', dim: true },
	faltou: { label: 'Faltou', tone: 'danger' },
	cancelado: { label: 'Cancelado', tone: null, strike: true }
};

// ---------------------------------------------------------------------------
// Minuto do dia ↔ "HH:MM"
// ---------------------------------------------------------------------------

export function m2t(minutes: number): string {
	const m = Math.max(0, Math.round(minutes));
	return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
}

// O caminho de volta ("HH:MM" → minuto) NÃO mora aqui: é o `timeToMinutes` de
// `scheduling.ts`, reexportado para quem consome a agenda não precisar saber disso. Havia
// uma segunda implementação neste arquivo (`t2m`) que devolvia 0 para lixo enquanto a de lá
// devolvia NaN — duas leituras do mesmo conceito com bordas opostas.
export { timeToMinutes };

// ---------------------------------------------------------------------------
// Fuso — instante absoluto ↔ relógio de parede da clínica
//
// `starts_at` é UTC; a grade é desenhada no horário LOCAL da clínica. Usar `getHours()`
// leria o fuso do PROCESSO (o container roda em UTC), desenhando a agenda inteira 3 horas
// fora do lugar — e o erro seria invisível em qualquer máquina que rodasse em UTC.
// ---------------------------------------------------------------------------

const partsCache = new Map<string, Intl.DateTimeFormat>();

function formatter(timezone: string): Intl.DateTimeFormat {
	let f = partsCache.get(timezone);
	if (!f) {
		f = new Intl.DateTimeFormat('en-CA', {
			timeZone: timezone,
			year: 'numeric',
			month: '2-digit',
			day: '2-digit',
			hour: '2-digit',
			minute: '2-digit',
			hour12: false
		});
		partsCache.set(timezone, f);
	}
	return f;
}

interface Wall {
	year: number;
	month: number;
	day: number;
	hour: number;
	minute: number;
}

function wallOf(ms: number, timezone: string): Wall {
	const out: Record<string, number> = {};
	for (const p of formatter(timezone).formatToParts(new Date(ms))) {
		if (p.type !== 'literal') out[p.type] = Number(p.value);
	}
	// `hour12: false` pode render "24" para meia-noite em algumas engines.
	return {
		year: out.year,
		month: out.month,
		day: out.day,
		hour: out.hour % 24,
		minute: out.minute
	};
}

/** Offset do fuso naquele instante, em minutos à frente do UTC (São Paulo = -180). */
function offsetAt(ms: number, timezone: string): number {
	const w = wallOf(ms, timezone);
	const asUtc = Date.UTC(w.year, w.month - 1, w.day, w.hour, w.minute);
	// Trunca ao minuto dos dois lados: `ms` pode carregar segundos que não aparecem no wall.
	return (asUtc - Math.floor(ms / 60000) * 60000) / 60000;
}

/** O dia local e o minuto do dia de um instante ISO, no fuso da clínica. */
export function zonedParts(iso: string, timezone: string): { date: string; minutes: number } {
	const w = wallOf(Date.parse(iso), timezone);
	const date = `${w.year}-${String(w.month).padStart(2, '0')}-${String(w.day).padStart(2, '0')}`;
	return { date, minutes: w.hour * 60 + w.minute };
}

// Relógio de parede da clínica → instante UTC. Política de DST fixada pelo doc 25 §4:
//  - AMBÍGUO (relógio atrasou; o horário acontece duas vezes) → a PRIMEIRA ocorrência;
//  - INEXISTENTE (relógio adiantou; o horário foi pulado) → empurra para DEPOIS do salto.
// O Brasil não tem DST desde 2019, mas `Clinic.timezone` é coluna livre — deixar isto
// implícito seria uma regra sem cobertura esperando a primeira clínica fora do país.
export function toUtcIso(date: string, time: string, timezone: string): string {
	const naive = Date.parse(`${date}T${time.length === 5 ? time : '00:00'}:00Z`);
	if (!Number.isFinite(naive)) return new Date(0).toISOString();

	// Os dois offsets possíveis em volta do instante (basta olhar ±24h: nenhuma transição
	// de fuso é mais longa que isso).
	const a = offsetAt(naive - 86400000, timezone);
	const b = offsetAt(naive + 86400000, timezone);
	const offsets = a === b ? [a] : [a, b];

	// Um candidato é VÁLIDO quando, lido de volta, reproduz o relógio pedido.
	const valid = offsets
		.map((o) => naive - o * 60000)
		.filter((c, i) => offsetAt(c, timezone) === offsets[i]);

	const picked = valid.length
		? Math.min(...valid) // ambíguo → primeira ocorrência
		: Math.max(...offsets.map((o) => naive - o * 60000)); // gap → depois do salto

	return new Date(picked).toISOString();
}

/** O "hoje" da clínica, a partir do `agora` do SERVIDOR (nunca de Date.now()). */
export function todayInZone(agoraIso: string, timezone: string): string {
	return zonedParts(agoraIso, timezone).date;
}

/** Anda dias numa data "YYYY-MM-DD" pela aritmética de calendário (imune a fuso). */
export function shiftDate(date: string, days: number): string {
	const [y, m, d] = date.split('-').map(Number);
	const dt = new Date(Date.UTC(y, m - 1, d + days));
	return dt.toISOString().slice(0, 10);
}

const LABEL_FMT = new Intl.DateTimeFormat('pt-BR', {
	weekday: 'long',
	day: 'numeric',
	month: 'long',
	timeZone: 'UTC'
});

/** "quinta-feira, 25 de junho", com " · hoje" quando for o dia corrente da clínica. */
export function dayLabel(date: string, today: string): string {
	const label = LABEL_FMT.format(new Date(`${date}T12:00:00Z`));
	return date === today ? `${label} · hoje` : label;
}

// ---------------------------------------------------------------------------
// As duas fronteiras temporais (RN-58)
//
// "Já começou" e "precisa de ação" são comparações DIFERENTES, e trocá-las é o bug clássico
// do port: uma olha o início, a outra o fim. `agora` vem SEMPRE do servidor.
// ---------------------------------------------------------------------------

export function started(appt: Appointment, agoraIso: string): boolean {
	return Date.parse(appt.starts_at) <= Date.parse(agoraIso);
}

/** Já terminou e ninguém resolveu: continua `agendado`/`confirmado` (protótipo :828). */
export function needsAction(appt: Appointment, agoraIso: string): boolean {
	if (appt.status !== 'agendado' && appt.status !== 'confirmado') return false;
	return Date.parse(appt.ends_at) <= Date.parse(agoraIso);
}

// ---------------------------------------------------------------------------
// Conflito — para EXIBIR, não para bloquear
//
// A-D2 decidiu a opção (b): o encaixe suprime o BLOQUEIO (a exclusion constraint tem o
// predicado `WHERE encaixe = false`), mas o conflito continua sendo calculado e mostrado.
// Divergência deliberada do protótipo, que apagava o encaixe do cálculo (:830/:835) e assim
// escondia exatamente a informação que motivou o encaixe: "este horário está dobrado".
// Cancelado, esse sim, não conflita em nenhum sentido.
// ---------------------------------------------------------------------------

/**
 * O agendamento DISPUTA espaço na grade? Fonte única da regra "cancelado não conta"
 * (doc 25 §7).
 *
 * Existia duas vezes, implícita: `conflictIds` filtrava cancelado, `layoutAppts` não sabia
 * o que era status. As duas leituras divergiram e o sintoma foi mudo — um cancelado
 * sobreposto alargava a coluna para duas raias (304px) sem o aviso de conflito acender.
 * Quem responde "não" continua sendo DESENHADO (riscado): não ocupar espaço é diferente de
 * não existir.
 */
export function ocupaGrade(appt: Pick<Appointment, 'status'>): boolean {
	return appt.status !== 'cancelado';
}

export function conflictIds(appts: Appointment[]): Set<string> {
	const out = new Set<string>();
	const live = appts.filter(ocupaGrade);

	for (let i = 0; i < live.length; i++) {
		for (let j = i + 1; j < live.length; j++) {
			const a = live[i];
			const b = live[j];
			if (a.professional_id !== b.professional_id) continue;
			// Estrito: encostar fim-com-início não é conflito (semântica `[)`).
			if (Date.parse(a.starts_at) < Date.parse(b.ends_at) && Date.parse(b.starts_at) < Date.parse(a.ends_at)) {
				out.add(a.id);
				out.add(b.id);
			}
		}
	}
	return out;
}

// ---------------------------------------------------------------------------
// Permissões (espelho de UX — a autoridade é a policy da API)
// ---------------------------------------------------------------------------

/** A8: recepção é quem agenda; profissional agenda a própria. */
export function canCreateAppointment(papel: Papel | null | undefined): boolean {
	return papel === 'owner' || papel === 'admin' || papel === 'recepcao' || papel === 'profissional';
}

/** A9 / D2: encaixe fura a grade, então é de quem responde pela agenda — profissional não. */
export function canCreateEncaixe(papel: Papel | null | undefined): boolean {
	return papel === 'owner' || papel === 'admin' || papel === 'recepcao';
}

// ---------------------------------------------------------------------------
// Ciclo de vida (Entrega 4) — espelho de UX; a autoridade é a policy/máquina do servidor
// ---------------------------------------------------------------------------

/** Quem mexe no ciclo de vida (remarcar, status) é quem agenda (A8). Mesma lista. */
export const canMutateAppointment = canCreateAppointment;

/** Estados terminais (D-E4.2): de onde "Reabrir" faz sentido. */
export function isTerminal(status: AppointmentStatus): boolean {
	return status === 'concluido' || status === 'faltou' || status === 'cancelado';
}

// Excluir (soft-delete, doc 40) só o que NÃO aconteceu: agendado/confirmado/cancelado. Espelho de
// UX do guard `StatusIn` do servidor — concluído/faltou/em_atendimento debitam pacote e
// cascatearam presença, então some do drawer (para desfazer um "faltou" errado: reabrir → excluir).
// Fonte única do que a UI mostra e do que a API aceita; divergir aqui pintaria um botão que o 422
// recusa.
export function canExcludeAppointment(status: AppointmentStatus): boolean {
	return status === 'agendado' || status === 'confirmado' || status === 'cancelado';
}

// As actions de ciclo de vida disparadas de DENTRO do drawer (não pelos modais criar/remarcar).
// Fonte única: o drawer usa esta lista para saber quais `form.error` são dele. Renomear uma
// action sem tocar aqui deixaria o erro do 409/422 sem aparecer no drawer — por isso não é uma
// lista solta no componente.
export const DRAWER_ACTIONS = [
	'cancelar',
	'reabrir',
	'excluir',
	// A2 (doc 41): presença por participante — os quatro verbos entram por uma action só.
	'presenca'
] as const;

// ---------------------------------------------------------------------------
// Presença por participante (A2, doc 41)
// ---------------------------------------------------------------------------

/** Os verbos das sub-rotas `/participants/:patient_id/…`. */
export type ParticipantKind = 'complete' | 'no_show' | 'reopen' | 'justify';

export interface ParticipantAction {
	kind: ParticipantKind;
	label: string;
	icon: string;
	/** Este é o estado atual da presença (destaque, não alvo de clique). */
	on: boolean;
	disabled: boolean;
	title: string;
}

/**
 * O que a linha de um participante oferece, no mesmo espírito do `statusActions` do bloco:
 * espelho de UX das regras do servidor (`transition_participant/6`), não a autoridade.
 *
 *  - `complete`/`no_show` ficam **desabilitados até a sessão começar** (RN-58, o mesmo
 *    `SessionStarted` do bloco) e só saem de `prevista`;
 *  - `reopen` desfaz um clique errado — sem gate de horário, como no servidor;
 *  - bloco **cancelado** não recebe presença nenhuma (o guard `block_not_open`, achado M-3 do
 *    bate-volta): a linha inteira fica sem ação, em vez de pintar botão que o 422 recusa.
 */
export function participantActions(
	p: Participant,
	appt: Appointment,
	agoraIso: string
): ParticipantAction[] {
	if (appt.status === 'cancelado' || p.status === 'cancelada') return [];

	const comecou = started(appt, agoraIso);
	const gated = comecou ? '' : 'Disponível após o horário da sessão';
	const resolvida = p.status === 'concluida' || p.status === 'faltou';

	if (resolvida) {
		return [
			{
				kind: 'reopen',
				label: 'Desfazer',
				icon: 'RotateCcw',
				on: false,
				disabled: false,
				title: 'Voltar para "previsto"'
			}
		];
	}

	return [
		{ kind: 'complete', label: 'Presente', icon: 'Check', on: false, disabled: !comecou, title: gated },
		{ kind: 'no_show', label: 'Faltou', icon: 'UserX', on: false, disabled: !comecou, title: gated }
	];
}

/** O rótulo e o tom de uma presença resolvida (a linha do drawer e o N/M do cabeçalho). */
export const ATTENDANCE_META: Record<AttendanceStatus, { label: string; tone?: string }> = {
	prevista: { label: 'Previsto' },
	concluida: { label: 'Presente', tone: 'success' },
	faltou: { label: 'Faltou', tone: 'danger' },
	cancelada: { label: 'Cancelada' }
};

/** Quantas presenças já foram resolvidas — o "2/4" do cabeçalho da turma. */
export function resolvedCount(participants: Participant[]): number {
	return participants.filter((p) => p.status === 'concluida' || p.status === 'faltou').length;
}

/**
 * A ação de status que sobrou no drawer: **cancelar**.
 *
 * Concluir e faltar saíram com a aposentadoria do eixo de bloco (A2, doc 41) — o desfecho é das
 * presenças e o status do bloco é o rollup delas (`participantActions/3`). Cancelar fica porque é
 * fase de AGENDAMENTO ("não vai acontecer"), não desfecho, e continua sendo escrita no bloco.
 * `on` marca a ação que já é o status atual.
 */
export interface StatusAction {
	kind: 'cancelar';
	label: string;
	status: AppointmentStatus;
	icon: string;
	on: boolean;
	disabled: boolean;
	title: string;
}

export function statusActions(appt: Appointment, _agoraIso: string): StatusAction[] {
	return [action('cancelar', 'Cancelar', 'cancelado', 'X', appt, false, '')];
}

function action(
	kind: StatusAction['kind'],
	label: string,
	status: AppointmentStatus,
	icon: string,
	appt: Appointment,
	disabled: boolean,
	title: string
): StatusAction {
	const on = appt.status === status;
	// A ação que já é o status atual nunca fica desabilitada (é o destaque, não um alvo de
	// clique); as outras respeitam o gate de "começou".
	return { kind, label, status, icon, on, disabled: disabled && !on, title };
}

// ---------------------------------------------------------------------------
// Geometria vertical da grade (A12)
// ---------------------------------------------------------------------------

export interface Range {
	start: number;
	end: number;
}

/** Faixa 08:00–18:00: no protótipo era regra; aqui é só o fallback de quando não há dado. */
export const DEFAULT_RANGE: Range = { start: 480, end: 1080 };

// Um período aceito pela geometria. A wire fala "HH:MM" (`Period` de `scheduling.ts`) e a
// grade fala minuto do dia; aceitar os dois evita uma passada de conversão em cada chamada.
export type PeriodLike = readonly [string | number, string | number];

const toMin = (v: string | number): number => (typeof v === 'number' ? v : timeToMinutes(v));

const floorHour = (m: number) => Math.floor(m / 60) * 60;
const ceilHour = (m: number) => Math.ceil(m / 60) * 60;

// A faixa vertical NÃO é 08–18 fixo (RN-03: aquilo era limite de renderização, não regra).
// Deriva do expediente das colunas visíveis e é ESTENDIDA para conter qualquer agendamento
// fora dele — senão um encaixe às 07:00 ficaria fora da área desenhada, invisível.
export function gridRange(periodsPerColumn: readonly PeriodLike[][], intervals: Range[]): Range {
	let min = Infinity;
	let max = -Infinity;

	for (const periods of periodsPerColumn) {
		for (const [ini, fim] of periods) {
			const a = toMin(ini);
			const b = toMin(fim);
			min = Math.min(min, a, b);
			max = Math.max(max, a, b);
		}
	}
	for (const iv of intervals) {
		min = Math.min(min, iv.start);
		max = Math.max(max, iv.end);
	}

	if (!Number.isFinite(min) || !Number.isFinite(max)) return { ...DEFAULT_RANGE };

	const start = Math.max(0, floorHour(min));
	const end = Math.min(1440, ceilHour(max));
	// Faixa degenerada (expediente de duração zero) ainda precisa de uma hora para desenhar.
	return end > start ? { start, end } : { start, end: Math.min(1440, start + 60) };
}

// O que hachurar numa coluna: todo pedaço da faixa que o profissional NÃO atende. Inclui as
// pontas (antes do primeiro período, depois do último), não só o vão do meio — é por isso
// que colunas com expedientes diferentes ficam visualmente diferentes, e isso é o correto
// (fecha o GAP-05: no protótipo o "ALMOÇO" era 12–13 cravado e igual em todas as colunas).
export function closedIntervals(periods: readonly PeriodLike[], range: Range): Array<[number, number]> {
	const spans = periods
		.map(([a, b]): [number, number] => {
			const ini = toMin(a);
			const fim = toMin(b);
			return [Math.max(range.start, Math.min(ini, fim)), Math.min(range.end, Math.max(ini, fim))];
		})
		.filter(([a, b]) => b > a)
		.sort((x, y) => x[0] - y[0]);

	const holes: Array<[number, number]> = [];
	let cursor = range.start;
	for (const [a, b] of spans) {
		if (a > cursor) holes.push([cursor, a]);
		cursor = Math.max(cursor, b);
	}
	if (cursor < range.end) holes.push([cursor, range.end]);
	return holes;
}

// Agendamento → retângulo na grade do dia local, aparado nos limites do dia.
//
// É AQUI que a regra de `ocupaGrade` cruza para a geometria, e de propósito: `layoutAppts`
// é geometria pura e não deve aprender o que é um status, mas também não pode receber os
// blocos sem saber quais disputam raia. O campo `ghost` é essa ponte — uma tradução só,
// feita num lugar só.
export function toInterval(appt: Appointment, timezone: string): Interval {
	const start = zonedParts(appt.starts_at, timezone).minutes;
	const durMin = Math.round((Date.parse(appt.ends_at) - Date.parse(appt.starts_at)) / 60000);
	// Bloco que viraria o dia é aparado em 24:00: a grade desenha UM dia. A continuação NÃO
	// aparece no dia seguinte — nem na Entrega 2, que trouxe as outras visões: a Semana e o Mês
	// creditam a duração inteira ao dia do `starts_at` (`occupancy_by_day/2` no backend), e a
	// Lista mostra só os blocos do dia buscado. Agendamento que atravessa a meia-noite é caso
	// não resolvido, não caso adiado para uma entrega nomeada.
	const end = Math.min(1440, start + Math.max(1, durMin));
	return { id: appt.id, start, end, ghost: !ocupaGrade(appt) };
}

// ---------------------------------------------------------------------------
// Estado navegável na URL (`?date=`, `?profs=`) — mesmo padrão de `?status=`/`?filter=`
// ---------------------------------------------------------------------------

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

export function parseDateParam(raw: string | null | undefined, fallback: string): string {
	if (!raw || !ISO_DATE.test(raw)) return fallback;
	// Rejeita data sintaticamente válida mas inexistente (2026-13-45).
	const ts = Date.parse(`${raw}T12:00:00Z`);
	if (!Number.isFinite(ts)) return fallback;
	return new Date(ts).toISOString().slice(0, 10) === raw ? raw : fallback;
}

/** `?profs=` lista os profissionais OCULTOS (o normal é ver todos — a URL fica limpa). */
export function parseHiddenProfs(raw: string | null | undefined): string[] {
	if (!raw) return [];
	return raw
		.split(',')
		.map((s) => s.trim())
		.filter(Boolean);
}

export function serializeHiddenProfs(ids: string[]): string | null {
	return ids.length ? ids.join(',') : null;
}
