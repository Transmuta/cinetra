import type { Actions, PageServerLoad } from './$types';
import { requestMagicLink, loadAuthPage } from '$lib/server/auth';

// Quem já está logado não vê o login de novo → home ou onboarding. O `loadAuthPage` faz essa
// guarda e ainda devolve a canônica desta página (está no sitemap, doc 57).
export const load: PageServerLoad = loadAuthPage;

// Login usa o default `register = false`: e-mail sem conta não recebe link nem vira cadastro.
export const actions: Actions = { default: requestMagicLink };
