import type { Actions, PageServerLoad } from './$types';
import { requestMagicLink, loadAuthPage } from '$lib/server/auth';

// Quem já está logado não vê o cadastro de novo → home ou onboarding. O `loadAuthPage` faz essa
// guarda e ainda devolve a canônica desta página (está no sitemap, doc 57).
export const load: PageServerLoad = loadAuthPage;

// Cadastro habilita registro: um e-mail novo recebe o link que cria a conta. O flag fica no
// servidor (não vem do formulário), então só esta rota registra — /entrar nunca cria conta.
export const actions: Actions = { default: (event) => requestMagicLink(event, true) };
