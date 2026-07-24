import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, type MutationResult } from './mutate';
import type { Package, PreviewResult } from '$lib/packages';

// BFF dos pacotes (Fatia 3 / ADR-005): fala com `/api/packages` server-to-server, repassando o
// cookie de sessão. `clinic_id` e RBAC vivem no escopo da API — o BFF nunca manda tenant no corpo.

// O corpo que cria (ou pré-visualiza) a série. `data_inicio` é "AAAA-MM-DD"; a grade é aninhada.
export interface SeriesInput {
	nome: string;
	total: number;
	falta_punitiva: boolean;
	cor: string;
	data_inicio: string;
	patient_id: string;
	appointment_type_id: string;
	grade: {
		dows: number[];
		horarios: Record<string, string>;
		professional_id: string;
	};
	// "agendar mesmo assim" — materializa conflito/turma cheia como encaixe. Nunca fura expediente.
	forcar?: boolean;
}

export interface PackagesResult {
	status: number;
	packages: Package[];
}

export async function fetchPatientPackages(
	event: RequestEvent,
	patientId: string
): Promise<PackagesResult> {
	try {
		const res = await apiFetch(event, `/api/patients/${encodeURIComponent(patientId)}/packages`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, packages: [] };
		const body = (await res.json()) as { packages: Package[] };
		return { status: res.status, packages: body.packages ?? [] };
	} catch {
		return { status: 0, packages: [] };
	}
}

// A prévia (save-gate): classifica a série sem escrever. Devolve `null` em falha de forma/conexão
// — a tela mostra o erro genérico e não desenha a grade fantasma.
export interface PreviewResponse {
	status: number;
	preview: PreviewResult | null;
}

export async function previewSeries(
	event: RequestEvent,
	input: SeriesInput
): Promise<PreviewResponse> {
	try {
		const res = await apiFetch(event, '/api/packages/preview', {
			method: 'POST',
			headers: { 'content-type': 'application/json', accept: 'application/json' },
			body: JSON.stringify(input)
		});
		if (!res.ok) return { status: res.status, preview: null };
		return { status: res.status, preview: (await res.json()) as PreviewResult };
	} catch {
		return { status: 0, preview: null };
	}
}

// Cria a série. Três desfechos: criado (201, devolve o pacote); bloqueado (422 `series_blocked`,
// devolve a prévia para a tela reapresentar com "agendar mesmo assim"); erro (mensagem). É o
// contrato do save-gate: a tela precisa distinguir "o mundo recusa, confirme" de "deu erro".
export interface CreateResult {
	ok: boolean;
	status: number;
	package?: Package;
	// quando 422 series_blocked:
	blocked?: { reason: 'fora_expediente' | 'precisa_confirmar'; preview: PreviewResult };
	error?: string;
}

export async function createSeries(
	event: RequestEvent,
	input: SeriesInput
): Promise<CreateResult> {
	try {
		const res = await apiFetch(event, '/api/packages', {
			method: 'POST',
			headers: { 'content-type': 'application/json', accept: 'application/json' },
			body: JSON.stringify(input)
		});

		if (res.status === 201) {
			const body = (await res.json()) as { package: Package };
			return { ok: true, status: 201, package: body.package };
		}

		if (res.status === 422) {
			const body = (await res.json()) as {
				error?: string;
				reason?: 'fora_expediente' | 'precisa_confirmar';
				preview?: PreviewResult;
			};
			if (body?.error === 'series_blocked' && body.reason && body.preview) {
				return { ok: false, status: 422, blocked: { reason: body.reason, preview: body.preview } };
			}
		}

		return { ok: false, status: res.status, error: 'Não foi possível criar o pacote.' };
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.' };
	}
}

// Ciclo de vida: pausar/retomar/cancelar operam sobre a série inteira. Reusa `mutate` (a escada
// de erros 401/403/404) — não precisam do corpo de volta, a tela recarrega a lista.
export function pausePackage(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/pause`, 'POST');
}

export function resumePackage(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/resume`, 'POST');
}

export function cancelPackage(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/cancel`, 'POST');
}

// Id escapado: um id forjado não sai do caminho do recurso (mesma defesa de `server/waitlist.ts`).
function path(id: string): string {
	return `/api/packages/${encodeURIComponent(id)}`;
}
