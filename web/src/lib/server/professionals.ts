import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, errorMessage, type MutationResult } from './mutate';
import type { Professional, ProfessionalsData, WeekdayMode } from '$lib/professionals';
import type { Period } from '$lib/scheduling';

// BFF da tela de Profissionais (fatia Profissionais / ADR-005): fala com `/api/professionals`
// server-to-server, repassando o cookie de sessão. O `clinic_id` e o RBAC vivem no escopo da
// API — o BFF nunca manda tenant nem papel no corpo.

// Corpo da ficha (create/update). `clinic_id`/`ativo` jamais entram (09 §8; ativo só muda por
// deactivate/reactivate). Tudo opcional menos o nome — a ficha é preenchível aos poucos.
export interface ProfessionalInput {
	nome: string;
	[field: string]: unknown;
}

// Um dia da grade a submeter: modo + períodos (só `custom` carrega períodos).
export interface DayInput {
	dow: number;
	modo: WeekdayMode;
	periods: Period[];
}

export interface ProfessionalsResult {
	status: number;
	data: ProfessionalsData | null;
}

export async function fetchProfessionals(event: RequestEvent): Promise<ProfessionalsResult> {
	try {
		const res = await apiFetch(event, '/api/professionals', {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as ProfessionalsData };
	} catch {
		return { status: 0, data: null };
	}
}

export interface ProfessionalResult {
	status: number;
	professional: Professional | null;
}

export async function fetchProfessional(
	event: RequestEvent,
	id: string
): Promise<ProfessionalResult> {
	try {
		const res = await apiFetch(event, path(id), { headers: { accept: 'application/json' } });
		if (!res.ok) return { status: res.status, professional: null };
		const body = (await res.json()) as { professional: Professional };
		return { status: res.status, professional: body.professional };
	} catch {
		return { status: 0, professional: null };
	}
}

// Create devolve o `id` criado — o save orquestra a grade logo em seguida (POST ficha → id →
// PATCH hours). Por isso não usa `mutate` (que descarta o corpo).
export interface CreateResult extends MutationResult {
	id?: string;
}

export async function createProfessional(
	event: RequestEvent,
	input: ProfessionalInput
): Promise<CreateResult> {
	try {
		const res = await apiFetch(event, '/api/professionals', {
			method: 'POST',
			headers: { 'content-type': 'application/json', accept: 'application/json' },
			body: JSON.stringify(input)
		});
		if (res.ok) {
			const body = (await res.json()) as { professional: Professional };
			return { ok: true, status: res.status, id: body.professional?.id };
		}
		return { ok: false, status: res.status, error: await errorMessage(res) };
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.' };
	}
}

export function updateProfessional(
	event: RequestEvent,
	id: string,
	input: ProfessionalInput
): Promise<MutationResult> {
	return mutate(event, path(id), 'PATCH', input);
}

export function deactivateProfessional(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/deactivate`, 'POST');
}

export function reactivateProfessional(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/reactivate`, 'POST');
}

// PATCH substitui a grade dos dias enviados (valida a semana inteira antes de escrever,
// incluindo o invariante prof ⊆ clínica).
// `confirm` é o A3/D12 — ver `updateClinicHours`. Estreitar a grade sobre sessão marcada volta
// 409 `future_conflicts` com a lista no `meta`.
export function updateProfessionalHours(
	event: RequestEvent,
	id: string,
	days: DayInput[],
	confirm = false
): Promise<MutationResult> {
	return mutate(event, `${path(id)}/hours`, 'PATCH', { days, confirm });
}

export function createProfessionalException(
	event: RequestEvent,
	id: string,
	input: { data: string; nome: string; tipo: string; periods: Period[] },
	confirm = false
): Promise<MutationResult> {
	return mutate(event, `${path(id)}/exceptions`, 'POST', { ...input, confirm });
}

export function deleteProfessionalException(
	event: RequestEvent,
	id: string,
	exceptionId: string
): Promise<MutationResult> {
	return mutate(event, `${path(id)}/exceptions/${encodeURIComponent(exceptionId)}`, 'DELETE');
}

// Lê e valida o payload do form da ficha (ficha + grade em JSON). Puro (sem event): a regra
// "nome e horário obrigatórios" é aplicada aqui, antes de qualquer chamada à API — nome não
// vazio e, quando o profissional NÃO segue a clínica, ao menos um dia `:custom`.
export type ParseResult =
	| { ok: true; ficha: ProfessionalInput; days: DayInput[] }
	| { ok: false; error: string };

export function parseProfessionalForm(fichaRaw: string, daysRaw: string): ParseResult {
	let ficha: unknown;
	let days: unknown;

	try {
		ficha = JSON.parse(fichaRaw);
	} catch {
		return { ok: false, error: 'Não foi possível ler a ficha.' };
	}

	if (!isRecord(ficha) || typeof ficha.nome !== 'string' || ficha.nome.trim() === '') {
		return { ok: false, error: 'O nome é obrigatório.' };
	}

	try {
		days = JSON.parse(daysRaw);
	} catch {
		return { ok: false, error: 'Não foi possível ler o horário.' };
	}

	if (!Array.isArray(days)) return { ok: false, error: 'Horário inválido.' };

	if (ficha.segue_horario_clinica === false && !days.some((d) => isRecord(d) && d.modo === 'custom')) {
		return { ok: false, error: 'Defina ao menos um dia de atendimento.' };
	}

	return { ok: true, ficha: ficha as ProfessionalInput, days: days as DayInput[] };
}

function isRecord(v: unknown): v is Record<string, unknown> {
	return typeof v === 'object' && v !== null && !Array.isArray(v);
}

// ---- Exceções encenadas no form: parse + reconciliação (create novas, apaga removidas) ----

export interface ExceptionInput {
	id: string | null; // preenchido = já existe; null = nova
	data: string;
	nome: string;
	tipo: string;
	periods: Period[];
}

export function parseExceptions(raw: string): ExceptionInput[] {
	try {
		const parsed = JSON.parse(raw);
		if (!Array.isArray(parsed)) return [];
		return parsed.filter(isRecord).map((e) => ({
			id: typeof e.id === 'string' ? e.id : null,
			data: String(e.data ?? ''),
			nome: String(e.nome ?? ''),
			tipo: String(e.tipo ?? 'fechado'),
			periods: Array.isArray(e.periods) ? (e.periods as Period[]) : []
		}));
	} catch {
		return [];
	}
}

// A leitura de "lista de ids num hidden com JSON" mora em `$lib/server/mutate` desde a Frente 13
// (D2, doc 29 §5) — eram três cópias, e esta era a que aceitava string vazia como id válido.
// Continua exportada daqui porque a ficha do profissional já a importava por este caminho.
export { parseIds } from './mutate';

// Aplica a situação (ativo) da ficha: como `ativo` não entra no corpo da ficha (só muda por
// deactivate/reactivate), o save compara o desejado com o original e chama o verbo certo. Sem
// mudança → no-op.
export function applyActiveState(
	event: RequestEvent,
	id: string,
	desired: boolean,
	original: boolean
): Promise<MutationResult> {
	if (desired === original) return Promise.resolve({ ok: true, status: 200 });
	return desired ? reactivateProfessional(event, id) : deactivateProfessional(event, id);
}

// Reconcilia as exceções do profissional: apaga as removidas (id original ausente do desejado)
// e cria as novas (sem id). Para na primeira falha, devolvendo o erro para virar mensagem.
export async function syncProfessionalExceptions(
	event: RequestEvent,
	id: string,
	desired: ExceptionInput[],
	originalIds: string[],
	confirm = false
): Promise<MutationResult> {
	const keep = new Set(desired.filter((e) => e.id).map((e) => e.id as string));

	for (const exId of originalIds.filter((oid) => !keep.has(oid))) {
		const res = await deleteProfessionalException(event, id, exId);
		if (!res.ok) return res;
	}

	for (const e of desired.filter((e) => !e.id)) {
		const res = await createProfessionalException(
			event,
			id,
			{ data: e.data, nome: e.nome, tipo: e.tipo, periods: e.periods },
			confirm
		);
		if (!res.ok) return res;
	}

	return { ok: true, status: 200 };
}

// Orquestra o save da ficha (comum a criar e editar): valida → persiste a ficha → grava a
// grade → reconcilia exceções → aplica a situação (ativo). Só o `persist` (create vs update),
// os ids de exceção originais e a situação original variam entre novo e edição; o resto é
// idêntico, então mora aqui (DRY). Devolve `{ ok: true }` (a rota faz o redirect) ou
// `{ ok: false, status, error }` para virar `fail`.
export interface RunSaveOpts {
	// Persiste a ficha e devolve `{ ok, id? }` (create devolve o id novo; update já tem o id).
	persist: (ficha: ProfessionalInput) => Promise<MutationResult & { id?: string }>;
	professionalId?: string;
	originalActive: boolean;
	originalExceptionIds: string[];
}

export async function runProfessionalSave(
	event: RequestEvent,
	form: FormData,
	opts: RunSaveOpts
): Promise<
	| { ok: true }
	| { ok: false; status: number; error?: string; code?: string; meta?: Record<string, unknown> }
> {
	// A3/D12 — a ficha é a QUARTA porta de edição de horário (grade + exceções do profissional).
	// O `confirm` atravessa a orquestração inteira: sem ele a API recusa a grade (ou a folga) que
	// deixaria sessão marcada fora do expediente, e o 409 sobe com a lista para a tela desenhar.
	const confirm = form.get('confirm') === 'true';
	const parsed = parseProfessionalForm(
		String(form.get('ficha') ?? ''),
		String(form.get('days') ?? '')
	);
	if (!parsed.ok) return { ok: false, status: 400, error: parsed.error };

	const persisted = await opts.persist(parsed.ficha);
	if (!persisted.ok) return { ok: false, status: persisted.status || 400, error: persisted.error };

	const id = opts.professionalId ?? persisted.id;
	if (!id) return { ok: false, status: 500, error: 'Não foi possível salvar o profissional.' };

	const hours = await updateProfessionalHours(event, id, parsed.days, confirm);

	if (!hours.ok) {
		return {
			ok: false,
			status: hours.status || 400,
			error: hours.error,
			code: hours.code,
			meta: hours.meta
		};
	}

	const exc = await syncProfessionalExceptions(
		event,
		id,
		parseExceptions(String(form.get('exceptions') ?? '[]')),
		opts.originalExceptionIds,
		confirm
	);

	if (!exc.ok) {
		return { ok: false, status: exc.status || 400, error: exc.error, code: exc.code, meta: exc.meta };
	}

	const st = await applyActiveState(
		event,
		id,
		String(form.get('ativo')) !== 'false',
		opts.originalActive
	);
	if (!st.ok) return { ok: false, status: st.status || 400, error: st.error };

	return { ok: true };
}

// O id chega de um campo de formulário (do cliente). Escapado, um id forjado como
// `../../auth/sign-out` não consegue sair do caminho do recurso.
function path(id: string): string {
	return `/api/professionals/${encodeURIComponent(id)}`;
}
