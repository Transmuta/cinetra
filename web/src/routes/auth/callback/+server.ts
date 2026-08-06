import { redirect, type RequestEvent } from '@sveltejs/kit';
import { apiBase, headersDeContexto, reemitSession } from '$lib/server/api';
import { registrarAceite } from '$lib/server/auth';

// Callback do magic link (ADR-005/015): o link do e-mail cai AQUI (no web), não na API.
// O BFF valida o token via API, captura o cookie de sessão e o re-emite no domínio do web.
export async function GET(event: RequestEvent) {
	const token = event.url.searchParams.get('token');
	if (!token) redirect(303, '/entrar?erro=link');

	// Sem `apiFetch` (não há sessão para repassar), mas COM o IP do cliente: sem ele, todos os
	// logins do sistema dividem o balde do container do BFF na API (doc 68, causa B).
	const res = await event.fetch(
		`${apiBase()}/api/auth/magic-link/callback?token=${encodeURIComponent(token)}`,
		{ redirect: 'manual', headers: headersDeContexto(event) }
	);

	if (!reemitSession(event, res)) redirect(303, '/entrar?erro=link');

	// O aceite dos documentos legais (`[D-14]`): depois da sessão assinada, porque é ela que
	// identifica quem aceitou. Não derruba o login se falhar — ver `registrarAceite`.
	await registrarAceite(event);

	redirect(303, '/');
}
