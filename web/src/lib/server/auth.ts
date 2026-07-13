import { fail, redirect, type RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import type { Me } from '$lib/session';

// Carrega a sessão (`/api/auth/me`) pelo BFF. Retorna `null` quando não há sessão válida.
// Usado pela home e pelo layout do app (guarda de auth). ADR-005: server-to-server.
export async function loadMe(event: RequestEvent): Promise<Me | null> {
	try {
		const res = await apiFetch(event, '/api/auth/me', { headers: { accept: 'application/json' } });
		if (!res.ok) return null;
		const body = await res.json();
		return body?.user ? (body as Me) : null;
	} catch {
		return null;
	}
}

// Para onde um usuário AUTENTICADO deve aterrissar: sem clínica ativa cai no onboarding
// (/comecar); com clínica, na home. Fonte ÚNICA do destino pós-login — usada pela guarda
// das páginas de auth e pelo próprio onboarding, para não duplicar essa regra.
export function landingPath(me: Me): string {
	return me.active_clinic_id ? '/' : '/comecar';
}

// Guarda das páginas protegidas fora do shell (ex.: /comecar): exige sessão. Sem sessão,
// manda para /entrar; com sessão, devolve o `me` já carregado (evita um segundo /me).
export async function requireSession(event: RequestEvent): Promise<Me> {
	const me = await loadMe(event);
	if (!me) redirect(303, '/entrar');
	return me;
}

// Guarda das páginas de autenticação (/entrar, /criar-conta): quem já tem sessão não vê o
// formulário de novo — vai para onde pertence (home ou onboarding).
export async function redirectIfAuthenticated(event: RequestEvent): Promise<void> {
	const me = await loadMe(event);
	if (me) redirect(303, landingPath(me));
}

// Action compartilhada por /entrar e /criar-conta: pede o magic link (ADR-015). O BFF só
// repassa para a API; a resposta é sempre neutra (não revela se o e-mail tem conta).
export async function requestMagicLink(event: RequestEvent) {
	const data = await event.request.formData();
	const email = String(data.get('email') ?? '').trim();
	// Nome só existe no cadastro (/criar-conta); em /entrar o campo nem é renderizado.
	const nome = String(data.get('nome') ?? '').trim();

	if (email === '') {
		return fail(400, { email, nome, error: 'Informe seu e-mail.' });
	}

	try {
		await apiFetch(event, '/api/auth/magic-link', {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify(nome ? { email, nome } : { email })
		});
	} catch {
		// Falha de rede não vira erro visível: resposta neutra (ADR-015).
	}

	return { sent: true, email };
}
