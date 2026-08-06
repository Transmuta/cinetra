import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { fetchPackageSessions } from '$lib/server/packages';
import type { PackageSessionsResponse } from '$lib/packages';

// A trilha do pacote (doc 69 §7 item 9), buscada sob demanda pelo modal "Sessões do pacote".
//
// Sob demanda, e não no `load` da ficha, porque é **uma leitura por pacote**: a ficha já faz seis
// em paralelo, e a trilha só interessa a quem abriu o modal daquele pacote.
//
// O `pkg` vem do path e é repassado como está — quem decide se aquele pacote é desta clínica é a
// API (404 pelo escopo), como em todas as outras rotas do BFF.
export const GET: RequestHandler = async (event) => {
	const r = await fetchPackageSessions(event, event.params.pkg);

	if (r.status && r.status >= 400) {
		return json({ sessions: [] } satisfies PackageSessionsResponse, { status: r.status });
	}

	return json({ sessions: r.sessions } satisfies PackageSessionsResponse);
};
