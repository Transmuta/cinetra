import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { loadMe, landingPath } from '$lib/server/auth';

// A raiz não renderiza nada: é um hub de redirecionamento (como /configuracoes leva à
// primeira seção pronta). Sem sessão → login; com sessão, vai para onde a pessoa pertence —
// onboarding se não tem clínica, senão a home do app, DENTRO do shell administrativo. ADR-005:
// o BFF resolve `me` server-to-server; o browser nunca fala direto com a API.
export const load: PageServerLoad = async (event) => {
	const me = await loadMe(event);
	if (!me) redirect(307, '/entrar');
	redirect(307, landingPath(me));
};
