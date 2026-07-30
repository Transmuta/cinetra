import { redirect, type RequestEvent } from '@sveltejs/kit';
import { apiFetch, SESSION_COOKIE } from '$lib/server/api';

// "Sair de todos os dispositivos" (tela Meu perfil). Como o sign-out comum, é POST (proteção
// CSRF do SvelteKit — GET permitiria logout forçado). Difere no alcance: a API revoga TODOS os
// tokens do usuário, inclusive o desta sessão. Depois apagamos o cookie local e voltamos a
// /entrar. Mesmo que a API falhe, o cookie daqui vai embora.
export async function POST(event: RequestEvent) {
	try {
		await apiFetch(event, '/api/auth/sign-out-everywhere', { method: 'POST' });
	} catch {
		// best-effort: o cookie local é apagado abaixo de qualquer forma.
	}
	event.cookies.delete(SESSION_COOKIE, { path: '/' });
	redirect(303, '/entrar');
}
