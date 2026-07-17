import type { Actions, PageServerLoad } from './$types';
import { requestMagicLink, redirectIfAuthenticated } from '$lib/server/auth';

// Quem já está logado não vê o login de novo → home ou onboarding (redirectIfAuthenticated).
export const load: PageServerLoad = redirectIfAuthenticated;

// Login usa o default `register = false`: e-mail sem conta não recebe link nem vira cadastro.
export const actions: Actions = { default: requestMagicLink };
