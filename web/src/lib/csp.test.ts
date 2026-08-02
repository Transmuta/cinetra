import { describe, it, expect } from 'vitest';
import { conferirOrigem, connectSrc, DEV_API_ORIGIN, imgSrc, wsOrigin } from './csp';
import { socketUrl } from './realtime';

// S3 (Onda 5). O `connect-src` listava `localhost:4010` **e** o host de produção, fixos: o build
// de prod carregava origem de dev. Inexplorável (ninguém serve localhost do browser do usuário),
// mas é a CSP dizendo uma coisa que o desenho não diz — e o próximo host entraria na lista pelo
// mesmo caminho.
describe('connectSrc (hosts da CSP por ambiente)', () => {
	it('deriva o par https/wss da origem pública da API', () => {
		expect(connectSrc('https://cinetra.com.br')).toEqual([
			'self',
			'https://cinetra.com.br',
			'wss://cinetra.com.br'
		]);
	});

	it('em http deriva ws (dev e o smoke de prod local)', () => {
		expect(connectSrc('http://localhost:4010')).toEqual([
			'self',
			'http://localhost:4010',
			'ws://localhost:4010'
		]);
	});

	// A regra de esquema é a MESMA de `socketUrl` (realtime.ts): quem monta a URL do socket e quem
	// a autoriza na CSP têm de concordar, senão o socket é bloqueado por um header que ninguém lê
	// até o browser reclamar.
	it('tolera barra no fim (a origem vem de env, não de código)', () => {
		expect(connectSrc('https://api.exemplo.com/')).toEqual([
			'self',
			'https://api.exemplo.com',
			'wss://api.exemplo.com'
		]);
	});

	// Sem env (dev local rodando `npm run dev` sem .env) cai no default do dev — o mesmo
	// `apiPublicOrigin()` do BFF usa.
	it('sem origem definida usa o default de desenvolvimento', () => {
		expect(connectSrc(undefined)).toEqual([
			'self',
			DEV_API_ORIGIN,
			DEV_API_ORIGIN.replace(/^http/, 'ws')
		]);
	});

	// O ponto do S3: o host de dev NÃO pode sobrar no build de produção.
	it('build de produção não carrega o host de dev', () => {
		expect(connectSrc('https://cinetra.com.br').join(' ')).not.toContain('localhost');
	});
});

// A foto de perfil do Google é copiada para o nosso bucket e servida por URL assinada — ou seja,
// o `<img>` do avatar aponta para o R2, não para `self`. Sem o bucket no `img-src`, a foto é
// bloqueada e o motivo fica só no console do browser de quem logou com Google (o mesmo modo de
// falha do `PUT` do anexo, doc 51 §5.3).
describe('imgSrc (a foto de perfil vem do bucket)', () => {
	it('inclui self, data: e o bucket quando há conta de R2', () => {
		expect(imgSrc('conta123')).toEqual([
			'self',
			'data:',
			'https://conta123.r2.cloudflarestorage.com'
		]);
	});

	// Sem `R2_ACCOUNT_ID` a fatia de storage já está desligada na API (503) e não há URL assinada
	// para servir foto nenhuma — abrir um destino a mais na política seria abrir por nada.
	it('sem conta de R2 fica só com self e data:', () => {
		expect(imgSrc(undefined)).toEqual(['self', 'data:']);
		expect(imgSrc('  ')).toEqual(['self', 'data:']);
	});

	// O `img-src` e o `connect-src` derivam do MESMO `r2Origin`: se um dia divergirem, o upload
	// funcionaria e a exibição não (ou o contrário), com o motivo escondido no console.
	it('o bucket é o mesmo host que o connect-src autoriza', () => {
		const bucket = imgSrc('conta123').at(-1);
		expect(connectSrc('https://cinetra.com.br', 'conta123')).toContain(bucket);
	});
});

// Bate-volta da Onda 5: a regra de esquema estava escrita DUAS vezes — aqui e no `socketUrl` —,
// cada uma com um comentário mandando concordar com a outra. Agora há uma fonte (`wsOrigin`), e
// este teste é o que prova que as duas pontas continuam de acordo: se divergirem, o browser
// bloqueia o socket por um header que só acusa no console.
describe('wsOrigin — a fonte única da regra de esquema', () => {
	it.each([
		['http://localhost:4010', 'ws://localhost:4010'],
		['https://cinetra.com.br', 'wss://cinetra.com.br'],
		['https://api.exemplo.com/', 'wss://api.exemplo.com']
	])('%s → %s', (origem, esperado) => {
		expect(wsOrigin(origem)).toBe(esperado);
	});

	it('a URL do socket e o connect-src da CSP apontam para a MESMA origem', () => {
		for (const origem of ['http://localhost:4010', 'https://cinetra.com.br']) {
			const autorizada = connectSrc(origem).find((o) => o.startsWith('ws'));
			expect(socketUrl(origem)).toBe(`${autorizada}/socket`);
		}
	});
});

// D2 (handoff do doc 47): a CSP é assada no BUILD e a origem do socket é lida em RUNTIME. Nada
// checava que as duas batem, e divergir bloqueia o WebSocket **em silêncio** — o erro só aparece
// no console do browser do usuário. Esta é a função que transforma o silêncio em falha de boot.
describe('conferirOrigem — a guarda entre o build e o runtime', () => {
	const autorizadas = connectSrc('https://cinetra.com.br');

	it('origem que a CSP autoriza passa', () => {
		expect(conferirOrigem(autorizadas, 'https://cinetra.com.br')).toBeNull();
	});

	it('tolera barra no fim dos dois lados', () => {
		expect(conferirOrigem(autorizadas, 'https://cinetra.com.br/')).toBeNull();
	});

	// O caso real: `environment:` do compose atualizado para o domínio novo, `args:` esquecido.
	it('origem de runtime fora da CSP vira mensagem — com os dois valores', () => {
		const erro = conferirOrigem(autorizadas, 'https://agenda.clinica.com.br');

		expect(erro).toContain('agenda.clinica.com.br');
		expect(erro).toContain('cinetra.com.br');
	});

	// O outro caso real: build sem o ARG. A CSP sai com localhost e produção disca o host real.
	it('build sem o ARG (CSP de dev) contra runtime de produção é pego', () => {
		const cspDeDev = connectSrc(undefined);

		expect(conferirOrigem(cspDeDev, 'https://cinetra.com.br')).toContain('localhost');
	});

	// Dev e CI: os dois lados caem no MESMO default, então a guarda não pode disparar por omissão
	// — só por divergência de verdade.
	it('sem configuração nenhuma, os dois lados batem (dev e CI não quebram)', () => {
		expect(conferirOrigem(connectSrc(undefined), DEV_API_ORIGIN)).toBeNull();
	});
});
