import type { Actions, PageServerLoad } from './$types';
import { requestMagicLink, redirectIfAuthenticated } from '$lib/server/auth';

// Quem já está logado não vê o login de novo → home ou onboarding (redirectIfAuthenticated).
export const load: PageServerLoad = redirectIfAuthenticated;

export const actions: Actions = { default: requestMagicLink };
