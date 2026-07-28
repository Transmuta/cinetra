import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

vi.mock('$lib/server/api', () => ({ apiBase: () => 'http://api:4000' }));

import { GET } from './+server';
import { GET as HEALTH } from '../health/+server';

/**
 * O alvo do monitor externo (doc 62 §9.4).
 *
 * O que estes testes protegem é a distinção entre os dois endpoints. Ela não é acadêmica: sem o
 * `/ready`, a única URL pública era a home, que responde 200 com a API inteiramente fora — porque
 * é conteúdo servido pelo Node. O monitor ficaria verde com o produto inutilizável.
 */

let saida: string[];

beforeEach(() => {
	saida = [];
	vi.spyOn(console, 'log').mockImplementation((linha: string) => void saida.push(linha));
});

afterEach(() => vi.restoreAllMocks());

function evento(fetchImpl: typeof fetch) {
	return { fetch: fetchImpl } as never;
}

describe('GET /health (liveness do BFF)', () => {
	it('200 sem tocar a API', async () => {
		const res = await HEALTH({} as never);

		expect(res.status).toBe(200);
		await expect(res.json()).resolves.toEqual({ status: 'ok', service: 'web' });
	});
});

describe('GET /ready (readiness do BFF)', () => {
	it('200 quando a API responde pronta', async () => {
		const res = await GET(evento(async () => new Response('{}', { status: 200 })));

		expect(res.status).toBe(200);
		await expect(res.json()).resolves.toEqual({ status: 'ok', service: 'web', api: 'ok' });
	});

	it('503 quando a API responde NÃO pronta', async () => {
		const res = await GET(evento(async () => new Response('{}', { status: 503 })));

		expect(res.status).toBe(503);
		await expect(res.json()).resolves.toMatchObject({ status: 'down', api: 'down' });
	});

	it('503 quando a API está inalcançável', async () => {
		const res = await GET(
			evento(async () => {
				throw new Error('connect ECONNREFUSED');
			})
		);

		expect(res.status).toBe(503);
		await expect(res.json()).resolves.toMatchObject({ status: 'down', api: 'unreachable' });
	});

	it('consulta o /api/ready da API, não outra rota', async () => {
		// Bater em `/api/health` (liveness) daria verde com o banco fora — o check inteiro
		// perderia o sentido, e em silêncio.
		let alvo = '';
		await GET(
			evento(async (url) => {
				alvo = String(url);
				return new Response('{}', { status: 200 });
			})
		);

		expect(alvo).toBe('http://api:4000/api/ready');
	});

	it('registra o motivo no log, mas NÃO no corpo da resposta', async () => {
		const res = await GET(
			evento(async () => {
				throw new Error('getaddrinfo ENOTFOUND api-interno.vcn.local');
			})
		);

		// O corpo é público: não descreve a topologia para quem varre a internet.
		const corpo = JSON.stringify(await res.json());
		expect(corpo).not.toContain('api-interno');

		// O motivo vai para o log, onde quem investiga alcança.
		expect(saida).toHaveLength(1);
		expect(saida[0]).toContain('api-interno');
		expect(JSON.parse(saida[0]).severity).toBe('warning');
	});
});
