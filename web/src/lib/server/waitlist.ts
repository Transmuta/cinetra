import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, type MutationResult } from './mutate';
import type { Entry, Professional, Rule, Slot, Priority, TimeWindow } from '$lib/waitlist';

// BFF da Fila de espera (doc 25, Entrega 5 / ADR-005): fala com `/api/waitlist` server-to-server,
// repassando o cookie de sessão. `clinic_id` e RBAC vivem no escopo da API — o BFF nunca manda
// tenant nem papel no corpo. Molde de `server/appointments.ts`: leitura devolve `{status, data}`
// (degrada para `data: null` na falha); escrita delega ao `mutate`, que propaga `{ok,code,error}`.

export interface WaitlistData {
	waitlist: Entry[];
	/** A barra lateral e a coluna "Preferência" precisam do diretório — vem junto do GET. */
	professionals: Professional[];
}

export interface WaitlistResult {
	status: number;
	data: WaitlistData | null;
}

export async function fetchWaitlist(event: RequestEvent): Promise<WaitlistResult> {
	try {
		const res = await apiFetch(event, '/api/waitlist', { headers: { accept: 'application/json' } });
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as WaitlistData };
	} catch {
		return { status: 0, data: null };
	}
}

export interface SlotsResult {
	status: number;
	data: { slots: Slot[] } | null;
}

// As vagas de UM item (o motor `find_slots`). Consumido pelo modal de Oferecer via `fetch` do
// cliente para o endpoint `/fila/[id]/slots` (não no load da lista: seriam N chamadas ao motor,
// uma por item — o mesmo N+1 que a agenda evitou no expediente).
export async function fetchSlots(event: RequestEvent, id: string): Promise<SlotsResult> {
	try {
		const res = await apiFetch(event, `${path(id)}/slots`, { headers: { accept: 'application/json' } });
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as { slots: Slot[] } };
	} catch {
		return { status: 0, data: null };
	}
}

// ---------------------------------------------------------------------------
// Escrita — cada corpo é o do contrato (doc 25 §5). `clinic_id` jamais entra.
// ---------------------------------------------------------------------------

// POST /waitlist é upsert-por-paciente (o `addFila` do protótipo): reinserir o mesmo paciente
// EDITA o item. `rules` substitui o conjunto inteiro (`manage_relationship :direct_control`).
export interface EnqueueInput {
	patient_id: string;
	prio: Priority;
	janela: TimeWindow;
	obs?: string;
	professional_ids: string[];
	rules: Rule[];
}

export function enqueueEntry(event: RequestEvent, input: EnqueueInput): Promise<MutationResult> {
	return mutate(event, '/api/waitlist', 'POST', input);
}

// PATCH parcial: só os campos presentes mudam. `rules` OMITIDO não apaga as regras (o controller
// só toca `rules` quando veio no corpo) — por isso é opcional aqui.
export interface UpdateInput {
	prio?: Priority;
	janela?: TimeWindow;
	obs?: string;
	professional_ids?: string[];
	rules?: Rule[];
}

export function updateEntry(event: RequestEvent, id: string, input: UpdateInput): Promise<MutationResult> {
	return mutate(event, path(id), 'PATCH', input);
}

export function dequeueEntry(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, path(id), 'DELETE');
}

// POST /:id/offer — segura a vaga por 10 min. O 409 `slot_held` (outra reserva viva cobre o
// horário) volta pelo `mutate` com `code`/`error` — a mensagem já diz quem está segurando.
export interface OfferInput {
	professional_id: string;
	/** UTC ISO. */
	starts_at: string;
	duration_minutos?: number;
}

export function offerSlot(event: RequestEvent, id: string, input: OfferInput): Promise<MutationResult> {
	return mutate(event, `${path(id)}/offer`, 'POST', input);
}

// POST /:id/convert — vira agendamento e sai da fila. `starts_at` já em UTC (o cliente converte
// pelo fuso da clínica). Propaga o 422 `schedule_conflict` quando o horário foi tomado no
// meio-tempo — o mesmo `code` de `createAppointment`, que a UI usa para oferecer o Encaixe.
export interface ConvertInput {
	starts_at: string;
	professional_id: string;
	appointment_type_id: string;
	encaixe?: boolean;
	obs?: string;
	duration_minutos?: number;
}

export function convertEntry(event: RequestEvent, id: string, input: ConvertInput): Promise<MutationResult> {
	return mutate(event, `${path(id)}/convert`, 'POST', input);
}

// O id chega de um campo de formulário (cliente). Escapado, um id forjado como `../appointments`
// não consegue sair do caminho do recurso e fazer o BFF chamar outro endpoint com a sessão do
// usuário — mesma defesa de `server/appointment-types.ts`.
function path(id: string): string {
	return `/api/waitlist/${encodeURIComponent(id)}`;
}
