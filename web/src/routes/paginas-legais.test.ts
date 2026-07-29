import { describe, it, expect, vi } from 'vitest';
import { load as privacidadeLoad } from './privacidade/+page.server';
import { load as termosLoad } from './termos/+page.server';
import { PAGINAS_PUBLICAS } from '$lib/seo';
import { DOCUMENTOS } from '$lib/legal';

const rotas = [
	{ caminho: '/privacidade', load: privacidadeLoad },
	{ caminho: '/termos', load: termosLoad }
];

// Evento de visitante COM cookie de sessão: é o caso que separa estas páginas das outras
// públicas. A raiz e as telas de auth redirecionam quem já tem sessão; um documento legal, não.
function fakeEvent(href: string) {
	const fetch = vi.fn();
	return {
		event: {
			url: new URL(href),
			fetch,
			cookies: { get: () => 'cookie-de-sessao' }
		} as never,
		fetch
	};
}

describe('/privacidade e /termos', () => {
	for (const { caminho, load } of rotas) {
		it(`${caminho}: devolve a canônica e a origem para o <head>`, async () => {
			const { event } = fakeEvent(`https://cinetra.app${caminho}?utm_source=rodape`);

			expect(await load(event)).toEqual({
				canonical: `https://cinetra.app${caminho}`,
				origem: 'https://cinetra.app'
			});
		});

		// Sem guarda de sessão, de propósito: quem está logado abre a política pelo rodapé e
		// continua lendo, em vez de ser jogado na agenda. E o robô não gasta rastreio em 302.
		it(`${caminho}: não consulta a sessão nem redireciona quem já entrou`, async () => {
			const { event, fetch } = fakeEvent(`https://cinetra.app${caminho}`);

			// Sem `redirect()` levantado e sem uma ida à API: a página é a mesma para todo mundo.
			expect(await load(event)).toBeTruthy();
			expect(fetch).not.toHaveBeenCalled();
		});
	}

	// Página legal que o robô não acha é página que não cumpre o papel de ser pública.
	it('as duas entram no sitemap', () => {
		const publicas = PAGINAS_PUBLICAS.map((p) => p.caminho);

		for (const doc of DOCUMENTOS) expect(publicas).toContain(doc.caminho);
	});
});
