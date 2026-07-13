import { fail, type RequestEvent } from '@sveltejs/kit';
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
