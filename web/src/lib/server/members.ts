import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, type MutationResult } from './mutate';
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
	try {
		const res = await apiFetch(event, '/api/members', { headers: { accept: 'application/json' } });
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as MembersData };
	} catch {
		// API fora / conexão recusada: status 0 para o load cair no `error(… || 502)` em vez de
		// deixar a exceção subir e virar 500. Mesmo contrato do BFF de tipos.
		return { status: 0, data: null };
	}
}

// O encanamento de mutação (request + escada de erros) mora em `./mutate`, compartilhado
// com os outros BFFs. Re-exportado porque nasceu aqui e é a assinatura destas funções.
export type { MutationResult };

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
	return mutate(event, memberPath(id), 'PATCH', input);
}

export async function revokeMember(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, memberPath(id), 'DELETE');
}

// O id vem de um campo de formulário (cliente). Escapado, um id forjado como
// `../../auth/sign-out` não sai do caminho do recurso. Simetria com o BFF de tipos.
function memberPath(id: string): string {
	return `/api/members/${encodeURIComponent(id)}`;
}

// Reenvia o convite = novo magic link para o e-mail (D24). Reusa o endpoint neutro de
// auth; ao clicar, o convidado entra e o vínculo pendente é ativado.
export async function resendInvite(event: RequestEvent, email: string): Promise<MutationResult> {
	return mutate(event, '/api/auth/magic-link', 'POST', { email });
}
