import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { loadMe } from '$lib/server/auth';

// BFF: tudo server-to-server na API Phoenix, repassando o cookie de sessão (ADR-005).
// O browser nunca fala direto com a API. Logado sem clínica cai no onboarding — fecha o
// beco do "nenhuma clínica ativa". Sem sessão, mostra a landing (CTA de entrar).
export const load: PageServerLoad = async (event) => {
	const me = await loadMe(event);
	if (me && !me.active_clinic_id) redirect(303, '/comecar');
	return { me };
};
