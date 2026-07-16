import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';

// Encanamento comum aos BFFs de mutação (Membros, Tipos de atendimento, …): dispara o
// request server-to-server e traduz a escada de erros da API (401/403/404/422) numa
// mensagem que a tela pode mostrar. Extraído de `server/members.ts` quando a segunda tela
// precisou exatamente do mesmo — a forma continua a de lá.

export interface MutationResult {
	ok: boolean;
	status: number;
	// mensagem de erro amigável (quando ok=false).
	error?: string;
}

export async function mutate(
	event: RequestEvent,
	path: string,
	method: string,
	body?: unknown
): Promise<MutationResult> {
	try {
		const res = await apiFetch(event, path, {
			method,
			headers: body
				? { 'content-type': 'application/json', accept: 'application/json' }
				: { accept: 'application/json' },
			body: body ? JSON.stringify(body) : undefined
		});
		if (res.ok) return { ok: true, status: res.status };
		return { ok: false, status: res.status, error: await errorMessage(res) };
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.' };
	}
}

export async function errorMessage(res: Response): Promise<string> {
	if (res.status === 403) return 'Você não tem permissão para esta ação.';
	if (res.status === 404) return 'Registro não encontrado.';
	try {
		const body = await res.json();
		if (body?.error === 'invalid') return 'Dados inválidos. Verifique os campos.';
	} catch {
		// corpo não-JSON: cai na mensagem genérica.
	}
	return 'Não foi possível concluir a operação.';
}
