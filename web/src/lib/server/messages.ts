import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, type MutationResult } from './mutate';
import type { MessagesData } from '$lib/messages';

// BFF da comunicação com o paciente (doc 52 §6 / ADR-005): fala com
// `/api/appointments/:id/messages` server-to-server, repassando o cookie de sessão. Quem decide
// o que sai, para quem e por quê é a API — aqui é encanamento.

export interface MessagesResult {
	status: number;
	data: MessagesData | null;
}

// A timeline de um agendamento. Falha silenciosa em `null`: o drawer do agendamento precisa
// abrir mesmo quando a comunicação está fora do ar — o bloco é o assunto principal da tela, a
// comunicação é o rodapé dele.
export async function fetchMessages(
	event: RequestEvent,
	appointmentId: string
): Promise<MessagesResult> {
	try {
		const res = await apiFetch(event, `/api/appointments/${appointmentId}/messages`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as MessagesData };
	} catch {
		return { status: 0, data: null };
	}
}

// Envia (ou reenvia) a confirmação. `patientId` recorta um participante — numa turma, reenviar
// para quem falhou não pode disparar para os outros três.
export async function sendConfirmation(
	event: RequestEvent,
	appointmentId: string,
	patientId?: string
): Promise<MutationResult> {
	return mutate(
		event,
		`/api/appointments/${appointmentId}/messages`,
		'POST',
		patientId ? { patient_id: patientId } : {}
	);
}
