import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { lookupCep } from './cep';

const fetchMock = vi.fn();

beforeEach(() => {
	fetchMock.mockReset();
	vi.stubGlobal('fetch', fetchMock);
});
afterEach(() => vi.unstubAllGlobals());

function res(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

describe('lookupCep', () => {
	it('menos de 8 dígitos → status null, sem chamar o BFF', async () => {
		expect(await lookupCep('123')).toEqual({ status: null });
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it('200 → ok + endereço (limpa a máscara antes de chamar)', async () => {
		fetchMock.mockResolvedValueOnce(
			res({ endereco: 'Avenida Paulista', bairro: 'Bela Vista', cidade: 'São Paulo', uf: 'SP' })
		);
		const r = await lookupCep('01310-100');
		expect(r.status).toBe('ok');
		expect(r.address?.cidade).toBe('São Paulo');
		expect(fetchMock).toHaveBeenCalledWith('/api/cep/01310100');
	});

	it('404 → notfound', async () => {
		fetchMock.mockResolvedValueOnce(new Response('', { status: 404 }));
		expect(await lookupCep('00000000')).toEqual({ status: 'notfound' });
	});

	it('outro erro HTTP → error', async () => {
		fetchMock.mockResolvedValueOnce(new Response('', { status: 500 }));
		expect(await lookupCep('01310100')).toEqual({ status: 'error' });
	});

	it('fetch lança → error', async () => {
		fetchMock.mockRejectedValueOnce(new Error('down'));
		expect(await lookupCep('01310100')).toEqual({ status: 'error' });
	});
});
