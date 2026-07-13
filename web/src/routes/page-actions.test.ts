import { describe, it, expect, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({ env: {} }));

import { actions as entrarActions, load as entrarLoad } from './entrar/+page.server';
import { actions as criarContaActions, load as criarContaLoad } from './criar-conta/+page.server';
import { requestMagicLink, redirectIfAuthenticated } from '$lib/server/auth';

// /entrar e /criar-conta compartilham a MESMA action (pedir magic link, ADR-015) e a MESMA
// guarda de load (quem já está logado é redirecionado, redirectIfAuthenticated).
describe('fiação de /entrar e /criar-conta', () => {
	it('ambas as actions apontam para requestMagicLink', () => {
		expect(entrarActions.default).toBe(requestMagicLink);
		expect(criarContaActions.default).toBe(requestMagicLink);
	});

	it('ambos os loads apontam para redirectIfAuthenticated', () => {
		expect(entrarLoad).toBe(redirectIfAuthenticated);
		expect(criarContaLoad).toBe(redirectIfAuthenticated);
	});
});
