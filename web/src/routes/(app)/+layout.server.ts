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

	// `me` e a contagem do sino são independentes, então a contagem parte junto e só é esperada
	// depois das guardas — poupa um round-trip no caminho autenticado, que é o comum no shell.
	//
	// O `.catch` não é decoração. Com `Promise.all`, uma REJEIÇÃO da contagem (API fora do ar)
	// sequestrava o fluxo: quem não tinha sessão levava 500 em vez de ir para `/entrar`. Isso era
	// impossível antes do paralelismo, porque o redirect acontecia antes da chamada. Não depender
	// do `try/catch` que vive lá dentro de `fetchUnreadCount` é o que mantém a garantia aqui,
	// onde ela é afirmada — e há teste vermelho para os dois casos.
	//
	// O custo do paralelismo, que existe: em hit NÃO autenticado ao shell (sessão expirada, bot,
	// link velho) a chamada da contagem sai assim mesmo e é descartada — 2 requisições à API onde
	// antes havia 1. São dois 401 baratos, sem banco, e o caminho autenticado é o dominante.
	const unread = fetchUnreadCount(event).catch(() => 0);
	const me = await loadMe(event);
	if (!me) redirect(303, '/entrar');
	if (!me.active_clinic_id) redirect(303, '/comecar');

	return { me, unread: await unread };
};
