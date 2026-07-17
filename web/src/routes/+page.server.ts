import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { loadMe, landingPath } from '$lib/server/auth';

// A raiz é a landing pública (Cinetra Landing.dc.html): visitante deslogado vê a página de
// marketing; quem já tem sessão não fica no marketing — vai para onde pertence (onboarding se
// não tem clínica, senão a home do app). ADR-005: o BFF resolve `me` server-to-server.
export const load: PageServerLoad = async (event) => {
	const me = await loadMe(event);
	if (me) redirect(307, landingPath(me));
	return {};
};
