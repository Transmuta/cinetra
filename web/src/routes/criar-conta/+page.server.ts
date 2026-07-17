import type { Actions, PageServerLoad } from './$types';
import { requestMagicLink, redirectIfAuthenticated } from '$lib/server/auth';

// Quem já está logado não vê o cadastro de novo → home ou onboarding (redirectIfAuthenticated).
export const load: PageServerLoad = redirectIfAuthenticated;

// Cadastro habilita registro: um e-mail novo recebe o link que cria a conta. O flag fica no
// servidor (não vem do formulário), então só esta rota registra — /entrar nunca cria conta.
export const actions: Actions = { default: (event) => requestMagicLink(event, true) };
