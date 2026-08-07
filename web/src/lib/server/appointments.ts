import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, type MutationResult } from './mutate';
import type {
	Appointment,
	AgendaProfessional,
	AgendaPatient,
	AgendaAppointmentType,
	AvailabilityDay
} from '$lib/agenda';
import type { DayCount } from '$lib/agenda-views';

// BFF da Agenda (doc 25 §5 / ADR-005): fala com `/api/appointments` e `/api/availability`
// server-to-server, repassando o cookie de sessão. `clinic_id` e RBAC vivem no escopo da
// API — o BFF nunca manda tenant nem papel no corpo.

export interface AgendaData {
	appointments: Appointment[];
	professionals: AgendaProfessional[];
	appointment_types: AgendaAppointmentType[];
	/**
	 * Instante do SERVIDOR. A linha do "agora" e o `needsAction` saem daqui e nunca de
	 * Date.now(): o relógio do browser é do usuário, pode estar errado por horas, e um
	 * "precisa de ação" calculado nele mentiria sobre o que já passou (ADR-009 / GAP-01).
	 */
	agora: string;
	timezone: string;
	/**
	 * Pacientes CITADOS na janela (derivados dos `patient_ids`), irmão de `professionals` e
	 * `appointment_types` — não o cadastro inteiro, que a lista de pacientes já ensinou a
	 * não carregar. Inclui arquivados (`ativo: false`) por decisão do contrato. Vem `[]`
	 * quando não há agendamentos no período.
	 */
	patients: AgendaPatient[];
}

export interface AgendaParams {
	from: string;
	/** Default = `from` (a visão Dia carrega um dia só). Teto de 31 dias é do servidor. */
	to?: string;
	professional_id?: string;
}

export function agendaQuery(params: AgendaParams): string {
	const qs = new URLSearchParams();
	qs.set('from', params.from);
	qs.set('to', params.to ?? params.from);
	if (params.professional_id) qs.set('professional_id', params.professional_id);
	return `?${qs.toString()}`;
}

export interface AgendaResult {
	status: number;
	data: AgendaData | null;
}

export async function fetchAgenda(
	event: RequestEvent,
	params: AgendaParams
): Promise<AgendaResult> {
	try {
		const res = await apiFetch(event, `/api/appointments${agendaQuery(params)}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as AgendaData };
	} catch {
		return { status: 0, data: null };
	}
}

export interface AvailabilityParams {
	// Vários numa requisição só: a API aceita `a,b,c`. Era um por chamada, e a agenda
	// compensava com uma requisição por coluna do dia (achado (f) do doc 26).
	professional_ids?: string[];
	date_from: string;
	date_to: string;
}

export function availabilityQuery(params: AvailabilityParams): string {
	const qs = new URLSearchParams();
	const ids = params.professional_ids ?? [];
	if (ids.length) qs.set('professional_id', ids.join(','));
	qs.set('date_from', params.date_from);
	qs.set('date_to', params.date_to);
	return `?${qs.toString()}`;
}

export interface ProfessionalAvailability {
	professional_id: string;
	days: AvailabilityDay[];
}

export interface AvailabilityResult {
	status: number;
	professionals: ProfessionalAvailability[];
}

// O expediente é a HACHURA da grade, não o conteúdo dela. Por isso a falha aqui degrada
// para "sem informação de expediente" em vez de derrubar a rota: uma agenda sem hachura
// ainda é utilizável; uma tela de erro no lugar da agenda não é.
export async function fetchAvailability(
	event: RequestEvent,
	params: AvailabilityParams
): Promise<AvailabilityResult> {
	try {
		const res = await apiFetch(event, `/api/availability${availabilityQuery(params)}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, professionals: [] };
		const body = (await res.json()) as { professionals?: ProfessionalAvailability[] };
		return { status: res.status, professionals: body.professionals ?? [] };
	} catch {
		return { status: 0, professionals: [] };
	}
}

// ---------------------------------------------------------------------------
// Contagens — as visões Semana e Mês (Entrega 2)
// ---------------------------------------------------------------------------

export interface CountsData {
	days: DayCount[];
	/** A barra lateral é a mesma nas quatro visões — sem isto, o toggle de ocultar fica vazio. */
	professionals: AgendaProfessional[];
	agora: string;
	timezone: string;
}

export interface CountsResult {
	status: number;
	data: CountsData | null;
}

/**
 * Contagens da janela. Ao contrário do expediente, a falha aqui **não** degrada: a barra é o
 * conteúdo destas visões, e um mês inteiro de cartões zerados afirmaria que não há agenda
 * nenhuma — pior que uma tela de erro, porque parece um dado.
 */
export async function fetchCounts(
	event: RequestEvent,
	params: { from: string; to: string }
): Promise<CountsResult> {
	const qs = new URLSearchParams({ from: params.from, to: params.to });

	try {
		const res = await apiFetch(event, `/api/appointments/counts?${qs.toString()}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as CountsData };
	} catch {
		return { status: 0, data: null };
	}
}

// ---------------------------------------------------------------------------
// Um bloco por id — resolve o link do drawer (`/agenda?agendamento=<id>`)
// ---------------------------------------------------------------------------

export interface AppointmentData {
	appointment: Appointment;
	/** Os pacientes citados no bloco, como no GET da janela: o bloco carrega ids, não nomes. */
	patients: AgendaPatient[];
	/**
	 * O fuso da clínica. É ele que transforma o `starts_at` (instante UTC) no **dia local** do
	 * bloco — a agenda que o link precisa carregar. Sem ele, um bloco às 22h30 de São Paulo
	 * (01:30Z do dia seguinte) abriria a agenda do dia errado.
	 */
	timezone: string;
}

export interface AppointmentResult {
	status: number;
	data: AppointmentData | null;
}

/**
 * O bloco de `?agendamento=<id>`, ou `null`.
 *
 * **404 é o caso normal aqui**, não a exceção: id inventado, bloco de outra clínica, excluído,
 * ou do colega quando o papel é `profissional` (o recorte A7 vive na leitura do domínio). Todos
 * degradam para `null` — link inválido abre a agenda de hoje, nunca uma tela de erro. É a mesma
 * decisão do `?paciente=` da ficha: conveniência de navegação não derruba tela.
 */
export async function fetchAppointment(
	event: RequestEvent,
	id: string
): Promise<AppointmentResult> {
	try {
		const res = await apiFetch(event, `/api/appointments/${encodeURIComponent(id)}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as AppointmentData };
	} catch {
		return { status: 0, data: null };
	}
}

// Corpo do POST (doc 25 §5). `ends_at` NÃO entra: é derivado no servidor a partir do tipo
// (A3) ou de `duration_minutos` (A-D8). `clinic_id` jamais entra.
export interface AppointmentInput {
	starts_at: string;
	professional_id: string;
	appointment_type_id: string;
	patient_ids: string[];
	encaixe?: boolean;
	obs?: string;
	duration_minutos?: number;
}

export function createAppointment(
	event: RequestEvent,
	input: AppointmentInput
): Promise<MutationResult> {
	return mutate(event, '/api/appointments', 'POST', input);
}

// ---------------------------------------------------------------------------
// Ciclo de vida (Entrega 4) — uma função por transição, espelho das rotas nomeadas
// (doc 25 §5). `expected_version` viaja em todas: é o guard de 409 (locking otimista).
// ---------------------------------------------------------------------------

/** Remarcar (arraste e modal). `starts_at` já em UTC; `professional_id` muda de coluna. */
export function rescheduleAppointment(
	event: RequestEvent,
	id: string,
	input: {
		starts_at: string;
		professional_id?: string;
		encaixe?: boolean;
		reschedule_reason?: string;
		// A pergunta do modal (2026-08-01). Sempre presente: ausente é `false` na API, e omitir
		// aqui tornaria a escolha da recepção indistinguível de um campo que não chegou.
		avisar_paciente: boolean;
		expected_version: number
	}
): Promise<MutationResult> {
	return mutate(event, `/api/appointments/${id}/reschedule`, 'PATCH', input);
}

export function cancelAppointment(
	event: RequestEvent,
	id: string,
	input: { cancel_reason?: string; avisar_paciente: boolean; expected_version: number }
) {
	return mutate(event, `/api/appointments/${id}/cancel`, 'POST', input);
}

export function reopenAppointment(event: RequestEvent, id: string, expected_version: number) {
	return mutate(event, `/api/appointments/${id}/reopen`, 'POST', { expected_version });
}

// Soft-delete de lançamento feito por engano (doc 40). Sem corpo próprio — só o guard de versão,
// como reopen; o backend recusa (422) se o bloco já aconteceu.
export function excludeAppointment(event: RequestEvent, id: string, expected_version: number) {
	return mutate(event, `/api/appointments/${id}/exclude`, 'POST', { expected_version });
}

// A2 (doc 41): `completeAppointment`/`missAppointment`/`justifyAbsence` saíram — o desfecho é da
// PRESENÇA, e as rotas de bloco foram aposentadas no servidor.

// ---------------------------------------------------------------------------
// Composição da turma (doc 109) — quem ENTRA e quem SAI de uma turma que já existe.
//
// É o eixo que faltava. A presença abaixo responde "o que aconteceu com quem estava marcado";
// esta dupla responde "quem está marcado" — e até aqui só tinha resposta de rabeira: entrar
// acontecia pelo merge do `createAppointment` no mesmo slot (o servidor funde, A-D4) e sair não
// tinha caminho nenhum pela tela.
//
// `expected_version` viaja nas duas, como no ciclo de vida: as duas mudam a composição do bloco,
// e é disso que o locking otimista protege.
// ---------------------------------------------------------------------------

/**
 * Acrescenta participantes a uma turma existente.
 *
 * `encaixe` fura o teto de capacidade (A-D3) e é guardado por policy (`owner`·`admin`·`recepcao`,
 * A9). Só viaja quando alguém de fato pediu: mandá-lo `false` sempre apagaria a diferença entre
 * "não pediu" e "pediu e não podia".
 *
 * Turma cheia volta 422 com `code: 'group_full'` — é por ele que a tela oferece o encaixe em vez
 * de só mostrar o vermelho, a mesma mecânica do `schedule_conflict` no criar.
 */
export function addParticipants(
	event: RequestEvent,
	id: string,
	input: { patient_ids: string[]; encaixe?: boolean; expected_version: number }
): Promise<MutationResult> {
	return mutate(event, `/api/appointments/${encodeURIComponent(id)}/participants`, 'POST', {
		patient_ids: input.patient_ids,
		...(input.encaixe ? { encaixe: true } : {}),
		expected_version: input.expected_version
	});
}

/**
 * Tira UM participante da turma. Os colegas não são tocados — cancelar o bloco cancelaria a
 * sessão de todo mundo, que é justamente o erro que esta rota existe para não obrigar.
 *
 * Duas recusas com `code` próprio: `last_participant` (422 — o bloco ficaria sem ninguém; o
 * caminho é cancelar) e 404 quando o paciente não está neste bloco.
 */
export function removeParticipant(
	event: RequestEvent,
	id: string,
	patientId: string,
	expected_version: number
): Promise<MutationResult> {
	// Ids escapados, como em `transitionParticipant`: um id forjado não sai do caminho do recurso.
	const path = `/api/appointments/${encodeURIComponent(id)}/participants/${encodeURIComponent(patientId)}`;
	return mutate(event, path, 'DELETE', { expected_version });
}

// ---------------------------------------------------------------------------
// Presença POR PARTICIPANTE (A2, doc 41) — as sub-rotas do bloco. Numa turma, concluir é de
// cada um: o desfecho do bloco vira rollup no servidor. `expected_version` continua sendo a do
// BLOCO (a versão vive lá), então o guard de 409 é o mesmo das ações de bloco.
// ---------------------------------------------------------------------------

/**
 * `complete` | `no_show` | `reopen` | `justify` — os verbos das sub-rotas. A declaração é uma só,
 * em `$lib/agenda` (onde mora a lista de runtime que a action valida); aqui é re-exportada para
 * quem já importa o BFF não ter de importar dois módulos.
 */
export type { ParticipantKind } from '$lib/agenda';
import type { ParticipantKind } from '$lib/agenda';

export function transitionParticipant(
	event: RequestEvent,
	id: string,
	patientId: string,
	kind: ParticipantKind,
	input: { expected_version: number; justificada?: boolean; motivo?: string }
): Promise<MutationResult> {
	// Ids escapados: um id forjado não sai do caminho do recurso (defesa de `server/waitlist.ts`).
	const path = `/api/appointments/${encodeURIComponent(id)}/participants/${encodeURIComponent(patientId)}/${kind}`;
	return mutate(event, path, 'POST', input);
}
