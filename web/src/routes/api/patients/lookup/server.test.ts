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

	// AN-10 (HOM-013, resto): o cadastro feito SEM documento — `?nome=&nascimento=` busca pelo
	// nome na API (que não filtra por data) e ESTE endpoint recorta por nascimento igual.
	describe('duplicado por nome + nascimento', () => {
		function evNome(nome: string, nascimento: string) {
			const qs = new URLSearchParams({ nome, nascimento });
			return { url: new URL(`http://localhost/api/patients/lookup?${qs}`) } as never;
		}

		it('busca pelo nome e devolve só quem tem o MESMO nascimento', async () => {
			apiFetch.mockResolvedValueOnce(
				json({
					patients: [
						{ id: 'p1', nome: 'Mariana Alves', cpf: null, tel: null, nascimento: '1990-05-20' },
						{ id: 'p2', nome: 'Mariana Alvarenga', cpf: null, tel: null, nascimento: '1980-01-01' },
						{ id: 'p3', nome: 'Mariana Alvim', cpf: null, tel: null, nascimento: null }
					]
				})
			);

			const res = await GET(evNome('Mariana Alves', '1990-05-20'));

			expect(apiFetch).toHaveBeenCalledWith(
				expect.anything(),
				expect.stringContaining('q=Mariana+Alves'),
				expect.anything()
			);
			expect(await res.json()).toEqual({
				matches: [{ id: 'p1', nome: 'Mariana Alves', cpf: null, tel: null }]
			});
		});

		it('nome curto ou data torta nem consultam', async () => {
			expect(await (await GET(evNome('Ma', '1990-05-20'))).json()).toEqual({ matches: [] });
			expect(await (await GET(evNome('Mariana', '20/05/1990'))).json()).toEqual({ matches: [] });
			expect(apiFetch).not.toHaveBeenCalled();
		});

		it('rede fora degrada para vazio, como no modo por documento', async () => {
			apiFetch.mockRejectedValueOnce(new Error('down'));
			expect(await (await GET(evNome('Mariana Alves', '1990-05-20'))).json()).toEqual({
				matches: []
			});
		});
	});
});
