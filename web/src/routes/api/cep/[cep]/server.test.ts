import { describe, it, expect, vi } from 'vitest';
import { GET } from './+server';

function ev(cep: string, fetchImpl: typeof fetch) {
	return { params: { cep }, fetch: fetchImpl } as never;
}

function viacep(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

describe('GET /api/cep/[cep]', () => {
	it('CEP válido → campos de endereço normalizados', async () => {
		const fetch = vi.fn(async () =>
			viacep({ logradouro: 'Avenida Paulista', bairro: 'Bela Vista', localidade: 'São Paulo', uf: 'SP' })
		) as unknown as typeof globalThis.fetch;

		const res = await GET(ev('01310-100', fetch));
		expect(res.status).toBe(200);
		expect(await res.json()).toEqual({
			endereco: 'Avenida Paulista',
			bairro: 'Bela Vista',
			cidade: 'São Paulo',
			uf: 'SP'
		});
		expect(fetch).toHaveBeenCalledWith('https://viacep.com.br/ws/01310100/json/');
	});

	it('CEP inexistente (erro:true do ViaCEP) → 404', async () => {
		const fetch = vi.fn(async () => viacep({ erro: true })) as unknown as typeof globalThis.fetch;
		await expect(GET(ev('00000000', fetch))).rejects.toMatchObject({ status: 404 });
	});

	it('menos de 8 dígitos → 400 sem tocar no ViaCEP', async () => {
		const fetch = vi.fn() as unknown as typeof globalThis.fetch;
		await expect(GET(ev('123', fetch))).rejects.toMatchObject({ status: 400 });
		expect(fetch).not.toHaveBeenCalled();
	});

	it('falha de rede no ViaCEP → 502', async () => {
		const fetch = vi.fn(async () => {
			throw new Error('down');
		}) as unknown as typeof globalThis.fetch;
		await expect(GET(ev('01310100', fetch))).rejects.toMatchObject({ status: 502 });
	});
});
