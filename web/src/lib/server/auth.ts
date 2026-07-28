import { fail, redirect, type RequestEvent } from '@sveltejs/kit';
import { apiFetch, SESSION_COOKIE } from './api';
import { canonical } from '$lib/seo';
import type { Me } from '$lib/session';

// Carrega a sessão (`/api/auth/me`) pelo BFF. Retorna `null` quando não há sessão válida.
// Usado pela home e pelo layout do app (guarda de auth). ADR-005: server-to-server.
export async function loadMe(event: RequestEvent): Promise<Me | null> {
	// Sem cookie de sessão não há o que perguntar: o `apiFetch` só identifica o usuário pelo
	// `_api_key`, então uma ida à API aqui volta 401 por construção. Ela custava um round-trip
	// server-to-server em CADA visita anônima — e as três páginas que mais recebem visitante
	// deslogado (landing, /entrar, /criar-conta) são exatamente as que passam por aqui. Doc 57.
	if (!event.cookies.get(SESSION_COOKIE)) return null;

	try {
		const res = await apiFetch(event, '/api/auth/me', { headers: { accept: 'application/json' } });
		if (!res.ok) return null;
		const body = await res.json();
		return body?.user ? (body as Me) : null;
	} catch {
		return null;
	}
}

// A "casa" do app: a agenda (A-D9, doc 25 §8). É a tela que a recepção abre de manhã e não
// fecha mais — o protótipo abre em `pacientes` [:267], mas o próprio `renderScreen` tem
// `default: renderAgenda` [:1316], e é este o comportamento que vale. Antes desta fatia
// apontava para /configuracoes/equipe, que era só a primeira tela construída.
export const APP_HOME = '/agenda';

// Para onde um usuário AUTENTICADO deve aterrissar: sem clínica ativa cai no onboarding
// (/comecar); com clínica, na home do app (dentro do shell). Fonte ÚNICA do destino
// pós-login — usada pela raiz, pela guarda das páginas de auth e pelo onboarding.
export function landingPath(me: Me): string {
	return me.active_clinic_id ? APP_HOME : '/comecar';
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

// O `load` das duas páginas de autenticação: a guarda acima mais o que o `<head>` precisa
// (`Seo.svelte`). As duas estão no sitemap (doc 57), e página listada no sitemap sem canônica é
// convite a conteúdo duplicado — `/entrar?erro=…` e `/criar-conta` chegam com query. A `origem`
// vai junto porque o `og:image` exige URL absoluta, e ela só existe no servidor (vem do ORIGIN).
export async function loadAuthPage(
	event: RequestEvent
): Promise<{ canonical: string; origem: string }> {
	await redirectIfAuthenticated(event);
	return { canonical: canonical(event.url), origem: event.url.origin };
}

// Action compartilhada por /entrar e /criar-conta: pede o magic link (ADR-015). O BFF só
// repassa para a API; a resposta é sempre neutra (não revela se o e-mail tem conta).
//
// `register` distingue cadastro de login e é FIXADO por rota no servidor (nunca vem do
// cliente): /criar-conta passa `true`, /entrar usa o default `false`. No login, um e-mail
// sem conta não recebe link (a API decide) — o "entrar" não vira cadastro nem enumera.
export async function requestMagicLink(event: RequestEvent, register = false) {
	const data = await event.request.formData();
	const email = String(data.get('email') ?? '').trim();
	// Nome só existe no cadastro (/criar-conta); em /entrar o campo nem é renderizado.
	const nome = String(data.get('nome') ?? '').trim();

	if (email === '') {
		return fail(400, { email, nome, error: 'Informe seu e-mail.' });
	}

	const payload: Record<string, unknown> = { email };
	if (nome) payload.nome = nome;
	if (register) payload.register = true;

	try {
		await apiFetch(event, '/api/auth/magic-link', {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify(payload)
		});
	} catch {
		// Falha de rede não vira erro visível: resposta neutra (ADR-015).
	}

	return { sent: true, email };
}
