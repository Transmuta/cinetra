import { describe, it, expect, vi } from 'vitest';
import { GET } from './+server';
import { AREAS_PRIVADAS } from '$lib/seo';

function fakeEvent(origem = 'https://cinetra.app') {
	const setHeaders = vi.fn();
	return { event: { url: new URL(`${origem}/robots.txt`), setHeaders } as never, setHeaders };
}

describe('GET /robots.txt', () => {
	it('aponta o sitemap com URL absoluta da origem do request', async () => {
		const { event } = fakeEvent();
		const txt = await (GET(event) as Response).text();

		expect(txt).toContain('Sitemap: https://cinetra.app/sitemap.xml');
	});

	it('bloqueia todas as áreas que exigem sessão', async () => {
		const { event } = fakeEvent();
		const txt = await (GET(event) as Response).text();

		for (const area of AREAS_PRIVADAS) {
			expect(txt).toContain(`Disallow: ${area}`);
		}
	});

	it('a landing continua liberada — o Disallow é de área privada, não do site', async () => {
		const { event } = fakeEvent();
		const txt = await (GET(event) as Response).text();

		expect(txt).toContain('User-agent: *');
		expect(txt).toContain('Allow: /');
		// A armadilha clássica: `Disallow: /` sozinho tira o site inteiro do índice.
		expect(txt).not.toMatch(/^Disallow: \/$/m);
	});

	it('serve como texto puro e é cacheável por uma hora', () => {
		const { event, setHeaders } = fakeEvent();
		const res = GET(event) as Response;

		expect(res.headers.get('content-type')).toBe('text/plain; charset=utf-8');
		expect(setHeaders).toHaveBeenCalledWith({ 'cache-control': 'public, max-age=3600' });
	});
});
