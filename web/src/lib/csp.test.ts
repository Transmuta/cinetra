import { describe, it, expect } from 'vitest';
import { conferirOrigem, connectSrc, DEV_API_ORIGIN, wsOrigin } from './csp';
import { socketUrl } from './realtime';

// S3 (Onda 5). O `connect-src` listava `localhost:4010` **e** o host de produção, fixos: o build
// de prod carregava origem de dev. Inexplorável (ninguém serve localhost do browser do usuário),
// mas é a CSP dizendo uma coisa que o desenho não diz — e o próximo host entraria na lista pelo
// mesmo caminho.
describe('connectSrc (hosts da CSP por ambiente)', () => {
	it('deriva o par https/wss da origem pública da API', () => {
		expect(connectSrc('https://movimento-api.fly.dev')).toEqual([
			'self',
			'https://movimento-api.fly.dev',
			'wss://movimento-api.fly.dev'
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
		expect(connectSrc('https://movimento-api.fly.dev').join(' ')).not.toContain('localhost');
	});
});

// Bate-volta da Onda 5: a regra de esquema estava escrita DUAS vezes — aqui e no `socketUrl` —,
// cada uma com um comentário mandando concordar com a outra. Agora há uma fonte (`wsOrigin`), e
// este teste é o que prova que as duas pontas continuam de acordo: se divergirem, o browser
// bloqueia o socket por um header que só acusa no console.
describe('wsOrigin — a fonte única da regra de esquema', () => {
	it.each([
		['http://localhost:4010', 'ws://localhost:4010'],
		['https://movimento-api.fly.dev', 'wss://movimento-api.fly.dev'],
		['https://api.exemplo.com/', 'wss://api.exemplo.com']
	])('%s → %s', (origem, esperado) => {
		expect(wsOrigin(origem)).toBe(esperado);
	});

	it('a URL do socket e o connect-src da CSP apontam para a MESMA origem', () => {
		for (const origem of ['http://localhost:4010', 'https://movimento-api.fly.dev']) {
			const autorizada = connectSrc(origem).find((o) => o.startsWith('ws'));
			expect(socketUrl(origem)).toBe(`${autorizada}/socket`);
		}
	});
});

// D2 (handoff do doc 47): a CSP é assada no BUILD e a origem do socket é lida em RUNTIME. Nada
// checava que as duas batem, e divergir bloqueia o WebSocket **em silêncio** — o erro só aparece
// no console do browser do usuário. Esta é a função que transforma o silêncio em falha de boot.
describe('conferirOrigem — a guarda entre o build e o runtime', () => {
	const autorizadas = connectSrc('https://movimento-api.fly.dev');

	it('origem que a CSP autoriza passa', () => {
		expect(conferirOrigem(autorizadas, 'https://movimento-api.fly.dev')).toBeNull();
	});

	it('tolera barra no fim dos dois lados', () => {
		expect(conferirOrigem(autorizadas, 'https://movimento-api.fly.dev/')).toBeNull();
	});

	// O caso real: `[env]` do fly.toml atualizado para o domínio novo, `[build.args]` esquecido.
	it('origem de runtime fora da CSP vira mensagem — com os dois valores', () => {
		const erro = conferirOrigem(autorizadas, 'https://agenda.clinica.com.br');

		expect(erro).toContain('agenda.clinica.com.br');
		expect(erro).toContain('movimento-api.fly.dev');
	});

	// O outro caso real: build sem o ARG. A CSP sai com localhost e produção disca o host real.
	it('build sem o ARG (CSP de dev) contra runtime de produção é pego', () => {
		const cspDeDev = connectSrc(undefined);

		expect(conferirOrigem(cspDeDev, 'https://movimento-api.fly.dev')).toContain('localhost');
	});

	// Dev e CI: os dois lados caem no MESMO default, então a guarda não pode disparar por omissão
	// — só por divergência de verdade.
	it('sem configuração nenhuma, os dois lados batem (dev e CI não quebram)', () => {
		expect(conferirOrigem(connectSrc(undefined), DEV_API_ORIGIN)).toBeNull();
	});
});
