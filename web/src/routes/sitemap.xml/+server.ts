import type { RequestHandler } from './$types';
import { PAGINAS_PUBLICAS } from '$lib/seo';

// Sitemap das páginas públicas (doc 57). Rota, e não arquivo em `static/`, porque a URL
// absoluta depende da origem (`ORIGIN` do fly.toml): um XML estático teria de repetir o
// domínio à mão e passaria a mentir no dia em que ele mudar.
export const GET: RequestHandler = ({ url, setHeaders }) => {
	const urls = PAGINAS_PUBLICAS.map(
		({ caminho, prioridade, frequencia }) => `	<url>
		<loc>${url.origin}${caminho}</loc>
		<changefreq>${frequencia}</changefreq>
		<priority>${prioridade}</priority>
	</url>`
	).join('\n');

	setHeaders({ 'cache-control': 'public, max-age=3600' });

	return new Response(
		`<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls}
</urlset>
`,
		{ headers: { 'content-type': 'application/xml; charset=utf-8' } }
	);
};
