import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { errorInfo, type MutationResult } from './mutate';
import type { MessagesData, SendOutcome } from '$lib/messages';

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

export interface SendResult extends MutationResult {
	/** Um por participante disparado. Vazio quando o pedido nem chegou a ser aceito. */
	resultados: SendOutcome[];
}

/**
 * Envia (ou reenvia) a confirmação. `patientId` recorta um participante — numa turma, reenviar
 * para quem falhou não pode disparar para os outros três.
 *
 * **Não usa o `mutate/4`**, e é a única razão de este código existir separado: aquele resolve
 * `ok` pelo status, e aqui o status não basta. A API responde **201 com o resultado por
 * participante** — o pedido foi aceito e o envio pode ter sido pulado (sem contato, canal
 * desligado, opt-out). Ler só o 201 fazia a tela dizer "Feito" sem nada ter saído.
 */
export async function sendConfirmation(
	event: RequestEvent,
	appointmentId: string,
	patientId?: string
): Promise<SendResult> {
	try {
		const res = await apiFetch(event, `/api/appointments/${appointmentId}/messages`, {
			method: 'POST',
			headers: { 'content-type': 'application/json', accept: 'application/json' },
			body: JSON.stringify(patientId ? { patient_id: patientId } : {})
		});

		if (!res.ok) return { ok: false, status: res.status, resultados: [], ...(await errorInfo(res)) };

		return { ok: true, status: res.status, resultados: parseResultados(await res.json()) };
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.', resultados: [] };
	}
}

// JSON não-tipado: só passa o que tem a forma esperada. No menor desvio a lista fica vazia — e
// lista vazia é tratada como "nada saiu", que é o lado seguro do erro (mesma postura do
// `parseDetails` em `mutate.ts`).
function parseResultados(body: unknown): SendOutcome[] {
	const raw = (body as { resultados?: unknown })?.resultados;
	if (!Array.isArray(raw)) return [];

	return raw.flatMap((item) => {
		if (typeof item !== 'object' || item === null) return [];
		const { patientId, enviado, motivo, agendadoPara } = item as Record<string, unknown>;
		if (typeof patientId !== 'string' || typeof enviado !== 'boolean') return [];

		return [
			{
				patientId,
				enviado,
				motivo: typeof motivo === 'string' ? motivo : null,
				// Preenchido = a janela de silêncio adiou. Ausente é o caso normal (sai agora), e
				// por isso o desvio de forma cai em `null` em vez de derrubar o resultado inteiro.
				agendadoPara: typeof agendadoPara === 'string' ? agendadoPara : null
			}
		];
	});
}
