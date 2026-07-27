import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, errorInfo, type MutationResult } from './mutate';
import type { Attachment, AttachmentLimits, UploadTicket } from '$lib/attachments';

// BFF dos anexos (doc 51 / ADR-005): fala com `/api/attachments` server-to-server, repassando o
// cookie de sessão. `clinic_id` e RBAC vivem no escopo da API.
//
// **O que este módulo NÃO faz: mover bytes.** O upload vai do browser direto ao R2 por URL
// assinada, e o download idem. Se algum dia um `apiFetch` daqui devolver um corpo de 50 MB, é
// porque alguém desfez o desenho — ver `05 §5.5`.

export interface AttachmentsResult {
	status: number;
	attachments: Attachment[];
	limites: AttachmentLimits | null;
}

export async function fetchPatientAttachments(
	event: RequestEvent,
	patientId: string
): Promise<AttachmentsResult> {
	try {
		const res = await apiFetch(
			event,
			`/api/patients/${encodeURIComponent(patientId)}/attachments`,
			{ headers: { accept: 'application/json' } }
		);

		// 403 é o caso do `profissional`: degrada para lista vazia em vez de derrubar a ficha
		// inteira — a seção nem é renderizada para ele.
		if (!res.ok) return { status: res.status, attachments: [], limites: null };

		const body = (await res.json()) as { attachments: Attachment[]; limites: AttachmentLimits };
		return { status: res.status, attachments: body.attachments ?? [], limites: body.limites ?? null };
	} catch {
		return { status: 0, attachments: [], limites: null };
	}
}

export interface StartUploadResult extends MutationResult {
	attachment?: Attachment;
	upload?: UploadTicket;
}

/** Passo 1 do upload: a API cria a linha `pendente` e assina o `PUT`. */
export async function startUpload(
	event: RequestEvent,
	patientId: string,
	input: { nome: string; content_type: string; bytes: number }
): Promise<StartUploadResult> {
	return comCorpo(event, `/api/patients/${encodeURIComponent(patientId)}/attachments`, 'POST', input);
}

/** Passo 3: o browser terminou o `PUT`; a API confere tamanho e magic bytes e libera. */
export async function confirmUpload(
	event: RequestEvent,
	id: string
): Promise<StartUploadResult> {
	return comCorpo(event, `/api/attachments/${encodeURIComponent(id)}/confirm`, 'POST');
}

// `mutate/4` devolve só ok/status — serve para quem não precisa da resposta. Estes dois precisam
// (a linha criada e o ticket de upload), então falam com o `apiFetch` direto e reaproveitam o
// `errorInfo` para a escada de erros continuar sendo uma só.
async function comCorpo(
	event: RequestEvent,
	path: string,
	method: string,
	body?: unknown
): Promise<StartUploadResult> {
	try {
		const res = await apiFetch(event, path, {
			method,
			headers: body
				? { 'content-type': 'application/json', accept: 'application/json' }
				: { accept: 'application/json' },
			body: body ? JSON.stringify(body) : undefined
		});

		if (!res.ok) return { ok: false, status: res.status, ...(await errorInfo(res)) };

		const data = (await res.json()) as { attachment: Attachment; upload?: UploadTicket };
		return { ok: true, status: res.status, attachment: data.attachment, upload: data.upload };
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.' };
	}
}

/** URL assinada de leitura. Cada emissão vira linha na trilha LGPD — não guardar nem reusar. */
export async function downloadUrl(
	event: RequestEvent,
	id: string
): Promise<{ ok: boolean; status: number; url?: string; error?: string }> {
	try {
		const res = await apiFetch(event, `/api/attachments/${encodeURIComponent(id)}/download`, {
			headers: { accept: 'application/json' }
		});

		if (!res.ok) return { ok: false, status: res.status, error: 'Não foi possível abrir o arquivo.' };

		const body = (await res.json()) as { url: string };
		return { ok: true, status: res.status, url: body.url };
	} catch {
		return { ok: false, status: 0, error: 'Não foi possível abrir o arquivo.' };
	}
}

export async function renameAttachment(
	event: RequestEvent,
	id: string,
	nome: string
): Promise<MutationResult> {
	return mutate(event, `/api/attachments/${encodeURIComponent(id)}`, 'PATCH', { nome });
}

export async function deleteAttachment(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `/api/attachments/${encodeURIComponent(id)}`, 'DELETE');
}
