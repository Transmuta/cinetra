import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, type MutationResult } from './mutate';
import type { ClinicException, ExceptionKind, Period } from '$lib/scheduling';

// BFF da tela de Exceções (doc 22 §3 / ADR-005): fala com `/api/clinic-exceptions`
// server-to-server. `clinic_id`/`professional_id` jamais no corpo — a rota é da clínica.

export interface ClinicExceptionsData {
	clinic_exceptions: ClinicException[];
}

export interface ClinicExceptionsResult {
	status: number;
	data: ClinicExceptionsData | null;
}

export async function fetchClinicExceptions(event: RequestEvent): Promise<ClinicExceptionsResult> {
	try {
		const res = await apiFetch(event, '/api/clinic-exceptions', {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as ClinicExceptionsData };
	} catch {
		return { status: 0, data: null };
	}
}

// Corpo do POST. `periods` só importa quando `tipo === 'horario'` — o servidor recusa
// horário sem período e fechado com período (H1). `nome` opcional.
export interface ClinicExceptionInput {
	data: string;
	nome: string;
	tipo: ExceptionKind;
	periods: Period[];
}

export function createClinicException(
	event: RequestEvent,
	input: ClinicExceptionInput
): Promise<MutationResult> {
	return mutate(event, '/api/clinic-exceptions', 'POST', input);
}

// Excluir é DELETE de verdade (H4). O id vem de um campo de formulário (cliente): escapado,
// um id forjado não sai do caminho do recurso.
export function deleteClinicException(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `/api/clinic-exceptions/${encodeURIComponent(id)}`, 'DELETE');
}
