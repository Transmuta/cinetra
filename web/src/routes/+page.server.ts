import type { PageServerLoad } from './$types';
import { loadMe } from '$lib/server/auth';

// BFF: tudo server-to-server na API Phoenix, repassando o cookie de sessão (ADR-005).
// O browser nunca fala direto com a API.
export const load: PageServerLoad = async (event) => {
	return { me: await loadMe(event) };
};
