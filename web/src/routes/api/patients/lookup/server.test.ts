import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiFetch = vi.fn();
vi.mock('$lib/server/api', () => ({ apiFetch: (...args: unknown[]) => apiFetch(...args) }));

import { GET } from './+server';

function ev(q: string) {
	return { url: new URL(`http://localhost/api/patients/lookup?q=${encodeURIComponent(q)}`) } as never;
}

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

beforeEach(() => apiFetch.mockReset());

describe('GET /api/patients/lookup', () => {
	it('termo curto não consulta a API', async () => {
		const res = await GET(ev('123'));

		expect(await res.json()).toEqual({ matches: [] });
		expect(apiFetch).not.toHaveBeenCalled();
	});

	it('documento completo → consulta só com dígitos e devolve o mínimo do aviso', async () => {
		apiFetch.mockResolvedValueOnce(
			json({
				patients: [
					{ id: 'p1', nome: 'João', cpf: '111.111.111-11', tel: null, medico: 'Dr. Sigiloso' }
				]
			})
		);

		const res = await GET(ev('111.111.111-11'));

		// a máscara não vai para a API, e o retorno NÃO carrega campos da ficha (só o aviso)
		expect(apiFetch).toHaveBeenCalledWith(
			expect.anything(),
			expect.stringContaining('q=11111111111'),
			expect.anything()
		);
		expect(await res.json()).toEqual({
			matches: [{ id: 'p1', nome: 'João', cpf: '111.111.111-11', tel: null }]
		});
	});

	it('API recusa (401) → lista vazia (o aviso nunca barra o cadastro)', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 401 }));

		expect(await (await GET(ev('11111111111'))).json()).toEqual({ matches: [] });
	});

	it('rede fora → lista vazia', async () => {
		apiFetch.mockRejectedValueOnce(new Error('down'));

		expect(await (await GET(ev('11111111111'))).json()).toEqual({ matches: [] });
	});
});
