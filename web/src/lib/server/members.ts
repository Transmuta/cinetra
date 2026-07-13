import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import type { MembersData } from '$lib/members';

// BFF da tela de Equipe & acessos (ADR-005): fala com `/api/members` server-to-server,
// repassando o cookie de sessão. O `clinic_id` e o RBAC vivem no escopo da API — o BFF
// nunca manda tenant nem papel do usuário no corpo.

export interface MembersResult {
	// null quando a API respondeu 401 (sem sessão) ou 403 (sem permissão) — o load decide.
	status: number;
	data: MembersData | null;
}

export async function fetchMembers(event: RequestEvent): Promise<MembersResult> {
	const res = await apiFetch(event, '/api/members', { headers: { accept: 'application/json' } });
	if (!res.ok) return { status: res.status, data: null };
	return { status: res.status, data: (await res.json()) as MembersData };
}

export interface MutationResult {
	ok: boolean;
	status: number;
	// mensagem de erro amigável (quando ok=false).
	error?: string;
}

export async function inviteMember(
	event: RequestEvent,
	input: { email: string; nome?: string; papel: string; professional_id?: string | null }
): Promise<MutationResult> {
	return mutate(event, '/api/members', 'POST', input);
}

export async function updateMember(
	event: RequestEvent,
	id: string,
	input: { papel?: string; professional_id?: string | null }
): Promise<MutationResult> {
	return mutate(event, `/api/members/${id}`, 'PATCH', input);
}

export async function revokeMember(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `/api/members/${id}`, 'DELETE');
}

// Reenvia o convite = novo magic link para o e-mail (D24). Reusa o endpoint neutro de
// auth; ao clicar, o convidado entra e o vínculo pendente é ativado.
export async function resendInvite(event: RequestEvent, email: string): Promise<MutationResult> {
	return mutate(event, '/api/auth/magic-link', 'POST', { email });
}

async function mutate(
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

async function errorMessage(res: Response): Promise<string> {
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
