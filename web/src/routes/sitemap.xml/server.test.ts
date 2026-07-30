import { describe, it, expect, vi } from 'vitest';
import { GET } from './+server';
import { PAGINAS_PUBLICAS } from '$lib/seo';

function fakeEvent(origem = 'https://cinetra.app') {
	const setHeaders = vi.fn();
	return { event: { url: new URL(`${origem}/sitemap.xml`), setHeaders } as never, setHeaders };
}

describe('GET /sitemap.xml', () => {
	it('lista todas as páginas públicas com URL absoluta da origem do request', async () => {
		const { event } = fakeEvent();
		const xml = await (GET(event) as Response).text();

		for (const { caminho } of PAGINAS_PUBLICAS) {
			expect(xml).toContain(`<loc>https://cinetra.app${caminho}</loc>`);
		}
		expect(xml.match(/<url>/g)).toHaveLength(PAGINAS_PUBLICAS.length);
	});

	it('a origem acompanha o ambiente (o XML não fixa domínio)', async () => {
		const { event } = fakeEvent('http://localhost:5173');
		const xml = await (GET(event) as Response).text();

		expect(xml).toContain('<loc>http://localhost:5173/</loc>');
		expect(xml).not.toContain('cinetra.app');
	});

	it('serve como XML e é cacheável por uma hora', async () => {
		const { event, setHeaders } = fakeEvent();
		const res = GET(event) as Response;

		expect(res.headers.get('content-type')).toBe('application/xml; charset=utf-8');
		expect(setHeaders).toHaveBeenCalledWith({ 'cache-control': 'public, max-age=3600' });
	});

	it('abre com a declaração XML na primeira linha (senão o robô recusa o arquivo)', async () => {
		const { event } = fakeEvent();
		const xml = await (GET(event) as Response).text();

		expect(xml.startsWith('<?xml version="1.0" encoding="UTF-8"?>')).toBe(true);
		expect(xml).toContain('xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"');
	});
});
