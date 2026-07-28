import { describe, it, expect, vi } from 'vitest';

vi.mock('$env/dynamic/private', () => ({ env: {} }));

import { actions as entrarActions, load as entrarLoad } from './entrar/+page.server';
import { actions as criarContaActions, load as criarContaLoad } from './criar-conta/+page.server';
import { requestMagicLink, loadAuthPage } from '$lib/server/auth';

// Evento com o email `addr` no formData e um fetch espião que devolve {ok:true}.
function fakeEvent(addr: string) {
	const fd = new FormData();
	fd.set('email', addr);
	const request = new Request('http://web/x', { method: 'POST', body: fd });
	const fetch = vi.fn().mockResolvedValue(new Response('{"ok":true}'));
	return { event: { request, fetch, cookies: { get: () => undefined } } as never, fetch };
}

// /entrar e /criar-conta compartilham a lógica (pedir magic link, ADR-015) e a guarda de load,
// mas DIVERGEM no intent de registro: só o cadastro habilita criar conta a partir de e-mail novo.
describe('fiação de /entrar e /criar-conta', () => {
	it('login (/entrar) usa requestMagicLink direto (register default = false)', () => {
		// Referência literal: login é a action compartilhada sem flag de registro.
		expect(entrarActions.default).toBe(requestMagicLink);
	});

	it('login não manda register no corpo (e-mail sem conta não vira cadastro)', async () => {
		const { event, fetch } = fakeEvent('ana@example.com');
		await entrarActions.default(event);
		expect(JSON.parse(fetch.mock.calls[0][1].body as string)).toEqual({ email: 'ana@example.com' });
	});

	it('cadastro (/criar-conta) manda register:true no corpo', async () => {
		const { event, fetch } = fakeEvent('ana@example.com');
		await criarContaActions.default(event);
		expect(JSON.parse(fetch.mock.calls[0][1].body as string)).toEqual({
			email: 'ana@example.com',
			register: true
		});
	});

	it('ambos os loads apontam para loadAuthPage (guarda de sessão + canônica)', () => {
		expect(entrarLoad).toBe(loadAuthPage);
		expect(criarContaLoad).toBe(loadAuthPage);
	});

	// As duas estão no sitemap (doc 57): sem canônica, `/entrar?erro=…` vira uma segunda URL da
	// mesma página no índice.
	it('os dois loads devolvem a canônica da própria página', async () => {
		const visitante = (href: string) =>
			({ fetch: vi.fn(), url: new URL(href), cookies: { get: () => undefined } }) as never;

		expect(await entrarLoad(visitante('https://cinetra.app/entrar?erro=expirado'))).toEqual({
			canonical: 'https://cinetra.app/entrar'
		});
		expect(await criarContaLoad(visitante('https://cinetra.app/criar-conta'))).toEqual({
			canonical: 'https://cinetra.app/criar-conta'
		});
	});
});
