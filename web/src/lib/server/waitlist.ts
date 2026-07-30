import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, type MutationResult } from './mutate';
import type {
	Entry,
	Professional,
	Rule,
	Slot,
	Priority,
	TimeWindow,
	WaitlistCounts
} from '$lib/waitlist';
import type { PageInfo } from '$lib/pagination';

// BFF da Fila de espera (doc 25, Entrega 5 / ADR-005): fala com `/api/waitlist` server-to-server,
// repassando o cookie de sessão. `clinic_id` e RBAC vivem no escopo da API — o BFF nunca manda
// tenant nem papel no corpo. Molde de `server/appointments.ts`: leitura devolve `{status, data}`
// (degrada para `data: null` na falha); escrita delega ao `mutate`, que propaga `{ok,code,error}`.

export interface WaitlistData {
	waitlist: Entry[];
	/** A barra lateral e a coluna "Preferência" precisam do diretório — vem junto do GET. */
	professionals: Professional[];
	/** Data local de hoje (ISO, ADR-009) para a lista marcar a regra `:data` no passado. */
	today: string;
	/** Recorte da página (F6) — o "X–Y de Z" do rodapé. */
	page: PageInfo;
	/** Contagens por prioridade da fila INTEIRA (a sidebar), do servidor. */
	counts: WaitlistCounts;
}

/** Janela pedida à API. As duas chamadas da tela (fila e vagas) usam a MESMA. */
export interface Janela {
	limit: number;
	offset: number;
	/** Segmento da sidebar. Filtra no SERVIDOR (F6) — filtrar a página seria filtrar o acaso. */
	prio?: string;
}

function qs({ limit, offset, prio }: Janela): string {
	const p = new URLSearchParams({ limit: String(limit), offset: String(offset) });
	if (prio && prio !== 'todas') p.set('prio', prio);
	return `?${p}`;
}

export interface WaitlistResult {
	status: number;
	data: WaitlistData | null;
}

export async function fetchWaitlist(event: RequestEvent, janela: Janela): Promise<WaitlistResult> {
	try {
		const res = await apiFetch(event, `/api/waitlist${qs(janela)}`, {
			headers: { accept: 'application/json' }
		});
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
// cliente para o endpoint `/fila/[id]/slots`.
export async function fetchSlots(event: RequestEvent, id: string): Promise<SlotsResult> {
	try {
		const res = await apiFetch(event, `${path(id)}/slots`, { headers: { accept: 'application/json' } });
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as { slots: Slot[] } };
	} catch {
		return { status: 0, data: null };
	}
}

/** `{ entry_id => vagas }` — o mapa que a lista usa para pintar o estado "tem vaga". */
export type SlotsByEntry = Record<string, Slot[]>;

export interface AllSlotsResult {
	status: number;
	data: { slots_by_entry: SlotsByEntry } | null;
}

// As vagas de TODA a fila numa passada (`GET /api/waitlist/slots`, o motor em lote). A lista
// enriquece cada linha com isto DEPOIS de renderizar — a falha degrada para o mapa vazio (a
// linha só não mostra a vaga), sem estourar. Batch de propósito: o endpoint por-item faria N
// chamadas ao motor a partir do load da lista.
export async function fetchAllSlots(event: RequestEvent, janela: Janela): Promise<AllSlotsResult> {
	try {
		const res = await apiFetch(event, `/api/waitlist/slots${qs(janela)}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as { slots_by_entry: SlotsByEntry } };
	} catch {
		return { status: 0, data: null };
	}
}

/** O slot de uma vaga que abriu — o `{professional_id, starts_at, ends_at}` do bloco. */
export interface CandidateSlot {
	professional_id: string;
	starts_at: string;
	ends_at: string;
}

export interface CandidatesResult {
	status: number;
	data: { candidates: Entry[] } | null;
}

// O "quem cabe aqui?" (AN-12, doc 64): os itens da fila cuja preferência + janela casam com a
// vaga que abriu (cancelamento/falta). Consumido pelo drawer via `/agenda/candidatos`.
export async function fetchCandidates(
	event: RequestEvent,
	slot: CandidateSlot
): Promise<CandidatesResult> {
	try {
		const qs = new URLSearchParams({
			professional_id: slot.professional_id,
			starts_at: slot.starts_at,
			ends_at: slot.ends_at
		});
		const res = await apiFetch(event, `/api/waitlist/candidates?${qs}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as { candidates: Entry[] } };
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
