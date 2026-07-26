import { describe, it, expect } from 'vitest';
import { connectSrc, DEV_API_ORIGIN } from './csp';

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
