import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';

// BFF do onboarding (ADR-005): cria a clínica via `POST /api/clinics` server-to-server,
// repassando o cookie de sessão. O usuário atual (ator do escopo da API) vira owner; o BFF
// nunca manda ator nem tenant no corpo (09 §8). O tenant ativo passa a resolver sozinho no
// próximo /me (único membership ativo), então não há cookie a re-emitir aqui.

export interface OnboardResult {
	ok: boolean;
	status: number;
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

		if (res.ok) return { ok: true, status: res.status };
		if (res.status === 422) return { ok: false, status: 422, error: 'Confira o nome da clínica.' };
		if (res.status === 401) return { ok: false, status: 401, error: 'Sua sessão expirou. Entre de novo.' };
		return { ok: false, status: res.status, error: 'Não foi possível criar a clínica.' };
	} catch {
		return { ok: false, status: 0, error: 'Falha de conexão com o servidor.' };
	}
}
