import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch, reemitSession } from './api';

// BFF do onboarding (ADR-005): cria a clínica via `POST /api/clinics` server-to-server,
// repassando o cookie de sessão. O usuário atual (ator do escopo da API) vira owner; o BFF
// nunca manda ator nem tenant no corpo (09 §8). No primeiro acesso o tenant ativo passa a
// resolver sozinho no próximo /me (único membership ativo). Já quando o dono cria uma clínica
// ADICIONAL (fluxo do menu), o tenant ativo continua o antigo — por isso devolvemos o id da
// clínica recém-criada, para o chamador poder trocar para ela com `switchTenant`.

export interface OnboardResult {
	ok: boolean;
	status: number;
	// id da clínica criada (quando ok) — usado para trocar o tenant ativo no fluxo "nova".
	clinicId?: string;
	// mensagem amigável (quando ok=false).
	error?: string;
}

export async function onboardClinic(event: RequestEvent, nome: string): Promise<OnboardResult> {
	try {
		const res = await apiFetch(event, '/api/clinics', {
			method: 'POST',
			headers: { 'content-type': 'application/json', accept: 'application/json' },
			body: JSON.stringify({ nome })
		});

		if (res.ok) {
			const body = (await res.json().catch(() => null)) as { clinic?: { id?: string } } | null;
			return { ok: true, status: res.status, clinicId: body?.clinic?.id };
		}
		if (res.status === 422) return { ok: false, status: 422, error: 'Confira o nome da clínica.' };
		if (res.status === 401) return { ok: false, status: 401, error: 'Sua sessão expirou. Entre de novo.' };
		return { ok: false, status: res.status, error: 'Não foi possível criar a clínica.' };
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.' };
	}
}

export interface SwitchResult {
	ok: boolean;
	status: number;
}

// Troca o tenant ativo da sessão (ADR-017). A API (`POST /api/auth/switch-tenant`) valida o
// vínculo ativo e reemite a sessão com o novo `clinic_id`; o BFF captura o Set-Cookie e o
// repassa no domínio do web — o mesmo padrão do callback de login (`reemitSession`). O
// browser nunca fala direto com a API.
export async function switchTenant(event: RequestEvent, clinicId: string): Promise<SwitchResult> {
	try {
		const res = await apiFetch(event, '/api/auth/switch-tenant', {
			method: 'POST',
			headers: { 'content-type': 'application/json', accept: 'application/json' },
			body: JSON.stringify({ clinic_id: clinicId })
		});
		if (res.ok) reemitSession(event, res);
		return { ok: res.ok, status: res.status };
	} catch {
		return { ok: false, status: 0 };
	}
}
