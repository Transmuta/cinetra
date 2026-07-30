import { describe, it, expect } from 'vitest';
import { acceptsGzip, compressible, gzipResponse } from './compress';

const html = (corpo: string, init: ResponseInit = {}) =>
	new Response(corpo, { headers: { 'content-type': 'text/html' }, ...init });

// Descomprime pelo padrão web (`DecompressionStream`), não por `node:zlib`: o tsconfig do
// projeto não carrega os tipos do Node de propósito (ver vite.config.ts), e o par
// Compression/Decompression é o mesmo que o browser usa do outro lado do fio.
const descomprimir = (res: Response) =>
	new Response(res.body!.pipeThrough(new DecompressionStream('gzip'))).text();

describe('acceptsGzip (negociação de conteúdo)', () => {
	it.each([
		['gzip', true],
		['gzip, deflate, br', true],
		['br, gzip;q=0.8', true],
		['*', true],
		['br, deflate', false],
		['', false],
		[null, false],
		// `q=0` é recusa explícita: mandar gzip mesmo assim é servir o que o cliente disse não ler.
		['gzip;q=0', false],
		['gzip;q=0, deflate', false],
		['deflate, gzip;q=0.0', false]
	])('%s → %s', (header, esperado) => {
		expect(acceptsGzip(header as string | null)).toBe(esperado);
	});
});

describe('compressible (vale a pena comprimir?)', () => {
	it('sim para HTML, JSON, XML, CSS, JS e SVG', () => {
		for (const t of [
			'text/html',
			'text/html; charset=utf-8',
			'application/json',
			'application/xml; charset=utf-8',
			'text/css',
			'application/javascript',
			'image/svg+xml'
		]) {
			expect(compressible(new Response('x', { headers: { 'content-type': t } })), t).toBe(true);
		}
	});

	it('não para binário já comprimido (imagem, fonte)', () => {
		for (const t of ['image/png', 'font/woff2', 'video/mp4']) {
			expect(compressible(new Response('x', { headers: { 'content-type': t } })), t).toBe(false);
		}
	});

	it('não quando já vem codificada (não se comprime duas vezes)', () => {
		const r = new Response('x', {
			headers: { 'content-type': 'text/html', 'content-encoding': 'br' }
		});
		expect(compressible(r)).toBe(false);
	});

	it('não quando não há corpo (204, 304)', () => {
		expect(compressible(new Response(null, { status: 204 }))).toBe(false);
	});
});

describe('gzipResponse', () => {
	const corpo = '<!doctype html><p>'.padEnd(4000, 'a') + '</p>';

	it('comprime o HTML e o resultado descomprime igual ao original', async () => {
		expect(await descomprimir(gzipResponse(html(corpo), 'gzip'))).toBe(corpo);
	});

	it('marca o content-encoding e encolhe o corpo de verdade', async () => {
		const res = gzipResponse(html(corpo), 'gzip');

		expect(res.headers.get('content-encoding')).toBe('gzip');
		expect((await res.arrayBuffer()).byteLength).toBeLessThan(corpo.length / 2);
	});

	it('apaga o content-length — o antigo faria o cliente truncar a leitura', () => {
		const original = html(corpo, { headers: { 'content-type': 'text/html', 'content-length': '4020' } });
		expect(gzipResponse(original, 'gzip').headers.get('content-length')).toBeNull();
	});

	it('preserva status e demais headers (os de segurança do hook vêm antes)', () => {
		const original = new Response(corpo, {
			status: 404,
			headers: { 'content-type': 'text/html', 'x-frame-options': 'DENY' }
		});
		const res = gzipResponse(original, 'gzip');

		expect(res.status).toBe(404);
		expect(res.headers.get('x-frame-options')).toBe('DENY');
	});

	it('sem gzip aceito: devolve o corpo cru, mas ainda marca o Vary', async () => {
		const res = gzipResponse(html(corpo), 'br');

		expect(res.headers.get('content-encoding')).toBeNull();
		expect(res.headers.get('vary')).toBe('accept-encoding');
		expect(await res.text()).toBe(corpo);
	});

	it('Vary sai também quando comprime — cache intermediário não pode trocar as variantes', () => {
		expect(gzipResponse(html(corpo), 'gzip').headers.get('vary')).toBe('accept-encoding');
	});

	it('resposta não compressível passa intocada (mesma instância)', () => {
		const original = new Response('x', { headers: { 'content-type': 'image/png' } });
		expect(gzipResponse(original, 'gzip')).toBe(original);
	});
});
