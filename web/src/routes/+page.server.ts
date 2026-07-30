import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { loadMe, landingPath } from '$lib/server/auth';
import { canonical } from '$lib/seo';

// A raiz é a landing pública (Cinetra Landing.dc.html): visitante deslogado vê a página de
// marketing; quem já tem sessão não fica no marketing — vai para onde pertence (onboarding se
// não tem clínica, senão a home do app). ADR-005: o BFF resolve `me` server-to-server.
export const load: PageServerLoad = async (event) => {
	const me = await loadMe(event);
	if (me) redirect(307, landingPath(me));

	// A canônica e a origem só existem no servidor (vêm do `ORIGIN`, doc 57): quem renderiza
	// as tags de `<head>` precisa recebê-las prontas para não inventar host no cliente.
	return { canonical: canonical(event.url), origem: event.url.origin };
};
