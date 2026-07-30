import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, type MutationResult } from './mutate';
import type { AppointmentTypesData } from '$lib/appointment-types';

// BFF da tela de Tipos de atendimento (doc 20 §3 / ADR-005): fala com `/api/appointment-types`
// server-to-server, repassando o cookie de sessão. O `clinic_id` e o RBAC vivem no escopo da
// API — o BFF nunca manda tenant nem papel do usuário no corpo.

export interface AppointmentTypesResult {
	// null quando a API não respondeu 2xx (ou nem respondeu) — o load decide.
	status: number;
	data: AppointmentTypesData | null;
}

export async function fetchAppointmentTypes(event: RequestEvent): Promise<AppointmentTypesResult> {
	try {
		const res = await apiFetch(event, '/api/appointment-types', {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as AppointmentTypesData };
	} catch {
		return { status: 0, data: null };
	}
}

// Corpo de create/update. `capacidade` é null quando não é grupo (01:474 — present sse grupo);
// `sigla` não entra: é derivada no servidor (T4). `clinic_id` jamais (09 §8).
export interface AppointmentTypeInput {
	nome: string;
	duracao_minutos: number;
	cor: string;
	icon: string;
	grupo: boolean;
	capacidade: number | null;
}

export function createAppointmentType(
	event: RequestEvent,
	input: AppointmentTypeInput
): Promise<MutationResult> {
	return mutate(event, '/api/appointment-types', 'POST', input);
}

export function updateAppointmentType(
	event: RequestEvent,
	id: string,
	input: AppointmentTypeInput
): Promise<MutationResult> {
	return mutate(event, path(id), 'PATCH', input);
}

// Arquivar/restaurar são transição de estado, não destroy (T2/T10) — daí POST /:id/<verbo>
// em vez de DELETE. Sem corpo: o verbo é a intenção inteira.
export function archiveAppointmentType(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/archive`, 'POST');
}

export function restoreAppointmentType(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `${path(id)}/restore`, 'POST');
}

// O id chega de um campo de formulário, ou seja: do cliente. Escapado, um id forjado como
// `../../auth/sign-out` não consegue sair do caminho do recurso e fazer o BFF chamar outro
// endpoint da API com a sessão do próprio usuário.
function path(id: string): string {
	return `/api/appointment-types/${encodeURIComponent(id)}`;
}
