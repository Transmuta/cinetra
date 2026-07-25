import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, errorMessage, type MutationResult } from './mutate';
import type { Patient, PatientsData } from '$lib/patients';

// BFF da tela de Pacientes (fatia Pacientes / ADR-005): fala com `/api/patients`
// server-to-server, repassando o cookie de sessão. O `clinic_id` e o RBAC vivem no escopo da
// API — o BFF nunca manda tenant nem papel no corpo.

// Corpo da ficha (create/update). `clinic_id`/`ativo` jamais entram (09 §8; ativo só muda por
// deactivate/reactivate). Tudo opcional menos o nome — a ficha é preenchível aos poucos.
export interface PatientInput {
	nome: string;
	[field: string]: unknown;
}

export interface PatientsResult {
	status: number;
	data: PatientsData | null;
}

// Recorte pedido à API. Busca e segmento são do servidor (a lista é paginada), então viajam
// como query string — não como filtro no cliente.
export interface PatientListParams {
	q?: string;
	filter?: string;
	limit?: number;
	offset?: number;
}

export function patientsQuery(params: PatientListParams = {}): string {
	const qs = new URLSearchParams();
	if (params.q) qs.set('q', params.q);
	// "todos" é o default da API — não sujar a URL com ele.
	if (params.filter && params.filter !== 'todos') qs.set('filter', params.filter);
	if (params.limit) qs.set('limit', String(params.limit));
	if (params.offset) qs.set('offset', String(params.offset));
	const s = qs.toString();
	return s ? `?${s}` : '';
}

export async function fetchPatients(
	event: RequestEvent,
	params: PatientListParams = {}
): Promise<PatientsResult> {
	try {
		const res = await apiFetch(event, `/api/patients${patientsQuery(params)}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as PatientsData };
	} catch {
		return { status: 0, data: null };
	}
}

export interface PatientResult {
	status: number;
	patient: Patient | null;
}

export async function fetchPatient(event: RequestEvent, id: string): Promise<PatientResult> {
	try {
		const res = await apiFetch(event, path(id), { headers: { accept: 'application/json' } });
		if (!res.ok) return { status: res.status, patient: null };
		const body = (await res.json()) as { patient: Patient };
		return { status: res.status, patient: body.patient };
	} catch {
		return { status: 0, patient: null };
	}
}

// Histórico de sessões da ficha (C13, Frente 7). É por PRESENÇA: numa turma o bloco pode estar
// concluído com a presença deste paciente faltando — por isso `status` (da presença) e
// `appointment_status` (do bloco) vêm separados. Degrada para lista vazia: a ficha inteira não
// cai por causa da seção de baixo.
export interface HistorySession {
	id: string;
	status: 'prevista' | 'concluida' | 'faltou' | 'cancelada';
	falta_justificada: boolean;
	package_id: string | null;
	appointment_id: string;
	starts_at: string;
	ends_at: string;
	appointment_status: string;
	obs: string | null;
	tipo: string | null;
	cor: string | null;
	profissional: string | null;
}

export interface HistoryResult {
	status: number;
	sessions: HistorySession[];
	more: boolean;
}

export async function fetchPatientHistory(
	event: RequestEvent,
	id: string
): Promise<HistoryResult> {
	try {
		const res = await apiFetch(event, `${path(id)}/history`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, sessions: [], more: false };
		const body = (await res.json()) as { sessions: HistorySession[]; more: boolean };
		return { status: res.status, sessions: body.sessions ?? [], more: !!body.more };
	} catch {
		return { status: 0, sessions: [], more: false };
	}
}

// Create devolve o `id` criado — o save aplica a situação (ativo) logo em seguida. Por isso não
// usa `mutate` (que descarta o corpo).
export interface CreateResult extends MutationResult {
	id?: string;
}

export async function createPatient(
	event: RequestEvent,
	input: PatientInput
): Promise<CreateResult> {
	try {
		const res = await apiFetch(event, '/api/patients', {
			method: 'POST',
			headers: { 'content-type': 'application/json', accept: 'application/json' },
			body: JSON.stringify(input)
		});
		if (res.ok) {
			const body = (await res.json()) as { patient: Patient };
			return { ok: true, status: res.status, id: body.patient?.id };
		}
		return { ok: false, status: res.status, error: await errorMessage(res) };
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.' };
	}
}

export function updatePatient(
	event: RequestEvent,
	id: string,
	input: PatientInput
): Promise<MutationResult> {
	return mutate(event, path(id), 'PATCH', input);
}

export function deactivatePatient(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/deactivate`, 'POST');
}

export function reactivatePatient(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/reactivate`, 'POST');
}

// Lê e valida o payload do form da ficha. Puro (sem event): a única regra do form é "nome não
// vazio" (o resto é opcional, salva-se aos poucos) — igual ao backend.
export type ParseResult = { ok: true; ficha: PatientInput } | { ok: false; error: string };

export function parsePatientForm(fichaRaw: string): ParseResult {
	let ficha: unknown;

	try {
		ficha = JSON.parse(fichaRaw);
	} catch {
		return { ok: false, error: 'Não foi possível ler a ficha.' };
	}

	if (!isRecord(ficha) || typeof ficha.nome !== 'string' || ficha.nome.trim() === '') {
		return { ok: false, error: 'O nome é obrigatório.' };
	}

	return { ok: true, ficha: ficha as PatientInput };
}

function isRecord(v: unknown): v is Record<string, unknown> {
	return typeof v === 'object' && v !== null && !Array.isArray(v);
}

// Orquestra o save da ficha (comum a criar e editar): valida → persiste. Só o `persist`
// (create vs update) varia entre novo e edição; o resto é idêntico, então mora aqui (DRY).
// Arquivar/reativar NÃO passa por aqui — é ação própria da ficha (deactivate/reactivate), fora
// do formulário (o form do protótipo tem só as 8 seções cadastrais, sem toggle de situação).
// Devolve `{ ok: true }` (a rota faz o redirect) ou `{ ok: false, status, error }` para `fail`.
export interface RunSaveOpts {
	persist: (ficha: PatientInput) => Promise<MutationResult & { id?: string }>;
}

export async function runPatientSave(
	_event: RequestEvent,
	form: FormData,
	opts: RunSaveOpts
): Promise<{ ok: true } | { ok: false; status: number; error?: string }> {
	const parsed = parsePatientForm(String(form.get('ficha') ?? ''));
	if (!parsed.ok) return { ok: false, status: 400, error: parsed.error };

	const persisted = await opts.persist(parsed.ficha);
	if (!persisted.ok) return { ok: false, status: persisted.status || 400, error: persisted.error };

	return { ok: true };
}

// O id vem do segmento de rota (`event.params.id`, do cliente). Escapado, um id forjado como
// `../../auth/sign-out` vira um único segmento (`..%2F..%2Fauth%2Fsign-out`) e não sai do
// caminho do recurso `/api/patients/:id`.
function path(id: string): string {
	return `/api/patients/${encodeURIComponent(id)}`;
}
