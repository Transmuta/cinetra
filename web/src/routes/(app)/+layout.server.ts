import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';
import { loadMe } from '$lib/server/auth';
import { fetchUnreadCount } from '$lib/server/notifications';

// Guarda de auth do shell administrativo: sem sessão, volta para /entrar. Com sessão mas
// sem clínica ativa, vai para o onboarding (/comecar) — o shell exige um tenant. ADR-005: o
// BFF resolve `me` server-to-server.
export const load: LayoutServerLoad = async (event) => {
	// O badge do sino (doc 31). `depends` deixa o tempo real revalidar SÓ esta contagem
	// (`invalidate('app:unread')`) quando chega uma notificação, sem recarregar a página.
	event.depends('app:unread');

	// `me` e a contagem do sino são independentes — dispara os dois em paralelo em vez de
	// encadear, poupando um round-trip no caminho autenticado (o comum no shell). Seguro:
	// `fetchUnreadCount` cai em 0 sem lançar, então o Promise.all não estraga os redirects
	// abaixo, que continuam mandando embora quem não tem sessão/clínica.
	const [me, unread] = await Promise.all([loadMe(event), fetchUnreadCount(event)]);
	if (!me) redirect(303, '/entrar');
	if (!me.active_clinic_id) redirect(303, '/comecar');

	return { me, unread };
};
