import { describe, it, expect, vi } from 'vitest';
import { handle } from './hooks.server';

// `aceita` = o Accept-Encoding do cliente. Por padrão nenhum, para os testes de header lerem a
// resposta crua; os testes de compressão pedem gzip explicitamente.
function fakeEvent(themeCookie?: string, url = 'http://localhost:5173/', aceita?: string) {
	return {
		cookies: { get: (n: string) => (n === 'mv-theme' ? themeCookie : undefined) },
		url: new URL(url),
		locals: {},
		request: new Request(url, { headers: aceita ? { 'accept-encoding': aceita } : {} })
	} as never;
}

// resolve mock: captura o transformPageChunk e devolve uma Response real — o `handle` seta
// os headers de segurança nela (doc 03 §4.4 + auditoria doc 13).
function fakeResolve(corpo = 'RESOLVED', tipo?: string) {
	let transform!: (opts: { html: string }) => string;
	const resolve = vi.fn((_e: unknown, opts: { transformPageChunk: typeof transform }) => {
		transform = opts.transformPageChunk;
		return new Response(corpo, tipo ? { headers: { 'content-type': tipo } } : undefined);
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

// H59 (Onda 5). O proxy da frente faz o REDIRECT http→https, mas não emite HSTS — o header tem
// de sair da aplicação. A premissa contrária estava escrita no doc 17 e no
// prod.exs, e teria ido para produção sem ninguém notar: o redirect esconde o sintoma.
describe('handle (HSTS, H59)', () => {
	async function headerEm(url: string) {
		const { resolve } = fakeResolve();
		const res = await handle({ event: fakeEvent(undefined, url), resolve } as never);
		return res.headers.get('Strict-Transport-Security');
	}

	it('em https emite Strict-Transport-Security com 2 anos e includeSubDomains', async () => {
		expect(await headerEm('https://cinetra.com.br/agenda')).toBe(
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
		// Mesmo cenário do adapter-node atrás do proxy: request http interno, ORIGIN https.
		const res = await handle({
			event: fakeEvent(undefined, 'https://cinetra.com.br/agenda'),
			resolve
		} as never);

		expect(res.headers.get('Strict-Transport-Security')).toBe(
			'max-age=63072000; includeSubDomains'
		);
	});
});

// Doc 57. O HTML do SSR saía cru — o `adapter-node` pré-comprime só os arquivos do build, e a
// proxy da frente não comprime nada (mesma lição do HSTS acima).
describe('handle (compressão do HTML do SSR)', () => {
	const html = '<!doctype html>'.padEnd(3000, 'x');

	it('cliente que aceita gzip recebe gzip, e os headers de segurança sobrevivem', async () => {
		const { resolve } = fakeResolve(html, 'text/html');
		const res = await handle({
			event: fakeEvent(undefined, 'https://cinetra.app/', 'gzip, deflate, br'),
			resolve
		} as never);

		expect(res.headers.get('content-encoding')).toBe('gzip');
		expect(res.headers.get('vary')).toBe('accept-encoding');
		// A compressão é o ÚLTIMO passo; se ela trocasse a resposta antes dos headers, sumiriam.
		expect(res.headers.get('X-Content-Type-Options')).toBe('nosniff');
		expect(res.headers.get('Strict-Transport-Security')).toBe(
			'max-age=63072000; includeSubDomains'
		);
	});

	it('cliente sem gzip recebe o HTML legível', async () => {
		const { resolve } = fakeResolve(html, 'text/html');
		const res = await handle({ event: fakeEvent(undefined, 'http://localhost:5173/'), resolve } as never);

		expect(res.headers.get('content-encoding')).toBeNull();
		expect(await res.text()).toBe(html);
	});
});

describe('handle (request_id para correlação com a API)', () => {
	// Um id POR REQUEST do BFF, e não por chamada: uma navegação dispara várias chamadas à API, e
	// o que se quer é vê-las juntas. Gerar dentro do `apiFetch` daria N ids sem relação entre si.
	it('põe um requestId em locals antes de resolver', async () => {
		const { resolve } = fakeResolve();
		const event = fakeEvent();
		await handle({ event, resolve } as never);

		const { requestId } = (event as unknown as { locals: { requestId?: string } }).locals;
		expect(requestId).toBeTypeOf('string');
		// A faixa que o `Plug.RequestId` aceita — fora dela ele descarta em silêncio.
		expect(new TextEncoder().encode(requestId).length).toBeGreaterThanOrEqual(20);
		expect(new TextEncoder().encode(requestId).length).toBeLessThanOrEqual(200);
	});

	// O `locals` precisa estar pronto ANTES do `resolve`, senão as chamadas que os `load` fazem à
	// API saem sem o header e a correlação fica valendo só para o que roda depois da página.
	it('o requestId já existe quando o resolve é chamado', async () => {
		let visto: string | undefined;
		const event = fakeEvent();
		const resolve = vi.fn(() => {
			visto = (event as unknown as { locals: { requestId?: string } }).locals.requestId;
			return new Response('ok');
		});
		await handle({ event, resolve } as never);

		expect(visto).toBeTypeOf('string');
	});

	it('cada request recebe um id diferente', async () => {
		const a = fakeEvent();
		const b = fakeEvent();
		await handle({ event: a, resolve: fakeResolve().resolve } as never);
		await handle({ event: b, resolve: fakeResolve().resolve } as never);

		const idA = (a as unknown as { locals: { requestId: string } }).locals.requestId;
		const idB = (b as unknown as { locals: { requestId: string } }).locals.requestId;
		expect(idA).not.toBe(idB);
	});
});
