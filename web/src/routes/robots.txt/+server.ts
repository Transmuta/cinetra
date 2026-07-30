import type { RequestHandler } from './$types';
import { AREAS_PRIVADAS } from '$lib/seo';

// robots.txt (doc 57). Era um arquivo em `static/` que liberava tudo e não apontava sitemap.
// Virou rota pela mesma razão do sitemap: a linha `Sitemap:` exige URL absoluta, e a origem
// só se conhece em runtime.
//
// O `Disallow` das áreas privadas não é segurança — quem protege é a sessão. É orçamento de
// rastreamento: sem ele o robô gasta as visitas do site em redirect para `/entrar` em vez de
// reler as páginas que podem ranquear.
export const GET: RequestHandler = ({ url, setHeaders }) => {
	setHeaders({ 'cache-control': 'public, max-age=3600' });

	const regras = AREAS_PRIVADAS.map((caminho) => `Disallow: ${caminho}`).join('\n');

	return new Response(
		`User-agent: *
${regras}
Allow: /

Sitemap: ${url.origin}/sitemap.xml
`,
		{ headers: { 'content-type': 'text/plain; charset=utf-8' } }
	);
};
