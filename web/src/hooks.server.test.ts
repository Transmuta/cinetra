import { describe, it, expect, vi } from 'vitest';
import { handle } from './hooks.server';

function fakeEvent(themeCookie?: string, url = 'http://localhost:5173/') {
	return {
		cookies: { get: (n: string) => (n === 'mv-theme' ? themeCookie : undefined) },
		url: new URL(url)
	} as never;
}

// resolve mock: captura o transformPageChunk e devolve uma Response real — o `handle` seta
// os headers de segurança nela (doc 03 §4.4 + auditoria doc 13).
function fakeResolve() {
	let transform!: (opts: { html: string }) => string;
	const resolve = vi.fn((_e: unknown, opts: { transformPageChunk: typeof transform }) => {
		transform = opts.transformPageChunk;
		return new Response('RESOLVED');
	});
	return { resolve, getTransform: () => transform };
}

// Roda o `handle` com um cookie de tema e devolve a função que aplica o transformPageChunk
// ao HTML servido — o mecanismo do dark mode sem flash.
function transformFor(themeCookie?: string) {
	const { resolve, getTransform } = fakeResolve();
	handle({ event: fakeEvent(themeCookie), resolve } as never);
	return (html: string) => getTransform()({ html });
}

const TEMPLATE = '<html lang="%mv-lang%"%mv-theme%>';

describe('handle (tema sem flash + lang pt-BR)', () => {
	it('cookie dark estampa data-theme="dark"', () => {
		expect(transformFor('dark')(TEMPLATE)).toBe('<html lang="pt-BR" data-theme="dark">');
	});

	it('cookie light estampa data-theme="light"', () => {
		expect(transformFor('light')(TEMPLATE)).toBe('<html lang="pt-BR" data-theme="light">');
	});

	it('sem cookie: NÃO estampa data-theme (deixa o prefers-color-scheme decidir)', () => {
		expect(transformFor(undefined)(TEMPLATE)).toBe('<html lang="pt-BR">');
	});

	it('cookie inválido: tratado como ausente', () => {
		expect(transformFor('azul')(TEMPLATE)).toBe('<html lang="pt-BR">');
	});
});

describe('handle (headers de segurança, auditoria doc 13)', () => {
	it('seta nosniff, X-Frame-Options DENY e Referrer-Policy na resposta', async () => {
		const { resolve } = fakeResolve();
		const res = await handle({ event: fakeEvent(), resolve } as never);

		expect(res.headers.get('X-Content-Type-Options')).toBe('nosniff');
		expect(res.headers.get('X-Frame-Options')).toBe('DENY');
		expect(res.headers.get('Referrer-Policy')).toBe('strict-origin-when-cross-origin');
	});
});

// H59 (Onda 5). O `force_https` do Fly faz o REDIRECT http→https, mas o proxy dele não emite
// HSTS — o header tem de sair da aplicação. A premissa contrária estava escrita no doc 17 e no
// prod.exs, e teria ido para produção sem ninguém notar: o redirect esconde o sintoma.
describe('handle (HSTS, H59)', () => {
	async function headerEm(url: string) {
		const { resolve } = fakeResolve();
		const res = await handle({ event: fakeEvent(undefined, url), resolve } as never);
		return res.headers.get('Strict-Transport-Security');
	}

	it('em https emite Strict-Transport-Security com 2 anos e includeSubDomains', async () => {
		expect(await headerEm('https://movimento-web.fly.dev/agenda')).toBe(
			'max-age=63072000; includeSubDomains'
		);
	});

	// Sobre http o header é ignorado por especificação (RFC 6797 §8.1) — emiti-lo em dev só
	// treinaria o olho a ver um header que não faz nada.
	it('em http NÃO emite o header', async () => {
		expect(await headerEm('http://localhost:5173/agenda')).toBeNull();
	});
});

// Bate-volta da Onda 5. O comentário do `handle` afirmava que a regra do protocolo protegia
// contra "HSTS de mentira num deploy http acidental". A sonda mostrou que NÃO: rodando a imagem
// de produção **sem `ORIGIN`**, o adapter-node assume `https` e o header saía sobre http puro.
// O que de fato decide é o `ORIGIN` estar setado e correto — então é ISSO que precisa de guarda,
// e é o que estes testes fixam.
describe('handle (o que decide o HSTS é o ORIGIN, não o fio)', () => {
	it('a origem reportada pelo SvelteKit é a fonte — é ela que o ORIGIN define', async () => {
		const { resolve } = fakeResolve();
		// Mesmo cenário do adapter-node atrás da edge do Fly: request http interno, ORIGIN https.
		const res = await handle({
			event: fakeEvent(undefined, 'https://movimento-web.fly.dev/agenda'),
			resolve
		} as never);

		expect(res.headers.get('Strict-Transport-Security')).toBe(
			'max-age=63072000; includeSubDomains'
		);
	});
});
