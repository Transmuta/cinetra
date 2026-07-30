import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiFetch = vi.fn();
vi.mock('$lib/server/api', () => ({ apiFetch: (...args: unknown[]) => apiFetch(...args) }));

import { GET } from './+server';

function ev(params: Record<string, string>) {
	const qs = new URLSearchParams(params);
	return { url: new URL(`http://localhost/api/patients/lookup?${qs}`) } as never;
}

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

// A ficha como a API a devolve: canônica (CPF só dígitos, telefone E.164, e-mail minúsculo).
function ficha(over: Record<string, unknown> = {}) {
	return {
		id: 'p1',
		nome: 'João Souza',
		cpf: null,
		tel: null,
		email: null,
		nascimento: null,
		ativo: true,
		...over
	};
}

beforeEach(() => apiFetch.mockReset());

describe('GET /api/patients/lookup', () => {
	it('sem identificação completa não consulta a API', async () => {
		const res = await GET(ev({ cpf: '123', tel: '119', email: 'ana@' }));

		expect(await res.json()).toEqual({ match: null });
		expect(apiFetch).not.toHaveBeenCalled();
	});

	it('CPF completo → consulta só com dígitos e devolve o mínimo do aviso', async () => {
		apiFetch.mockResolvedValueOnce(json({ patients: [ficha({ cpf: '11144477735' })] }));

		const res = await GET(ev({ cpf: '111.444.777-35' }));

		// a máscara não vai para a API, e o retorno NÃO carrega campos da ficha (só o aviso)
		expect(apiFetch).toHaveBeenCalledWith(
			expect.anything(),
			expect.stringContaining('q=11144477735'),
			expect.anything()
		);
		expect(await res.json()).toEqual({
			match: { id: 'p1', nome: 'João Souza', campo: 'CPF', ativo: true }
		});
	});

	// O BUG que motivou o redesenho: o cliente escolhia UM termo, e o CPF tinha prioridade —
	// com o CPF preenchido, telefone repetido não era consultado e passava sem aviso até o 422.
	it('telefone repetido é avisado mesmo com o CPF preenchido e sem colisão', async () => {
		apiFetch
			.mockResolvedValueOnce(json({ patients: [] }))
			.mockResolvedValueOnce(json({ patients: [ficha({ tel: '+5511987654321' })] }));

		const res = await GET(ev({ cpf: '111.444.777-35', tel: '(11) 98765-4321' }));

		expect(apiFetch).toHaveBeenCalledTimes(2);
		expect(await res.json()).toEqual({
			match: { id: 'p1', nome: 'João Souza', campo: 'celular', ativo: true }
		});
	});

	it('e-mail repetido é avisado, e a caixa não conta', async () => {
		apiFetch.mockResolvedValueOnce(json({ patients: [ficha({ email: 'ana@example.com' })] }));

		const res = await GET(ev({ email: '  ANA@Example.com ' }));

		expect(await res.json()).toEqual({
			match: { id: 'p1', nome: 'João Souza', campo: 'e-mail', ativo: true }
		});
	});

	// A busca da API é por SUBSTRING (`LIKE %termo%`), então ela devolve vizinhos: um fixo de 10
	// dígitos é sufixo de celulares, e "45678" casa vários CPFs. Quem decide se é o MESMO valor é
	// o recorte canônico daqui — sem ele o aviso acusaria duplicado onde não há.
	it('vizinho que só casa por substring NÃO é duplicado', async () => {
		apiFetch.mockResolvedValueOnce(json({ patients: [ficha({ tel: '+5511987654321' })] }));

		const res = await GET(ev({ tel: '(11) 8765-4321' }));

		expect(await res.json()).toEqual({ match: null });
	});

	it('a própria ficha em edição é ignorada (`exclude`)', async () => {
		apiFetch.mockResolvedValueOnce(json({ patients: [ficha({ id: 'eu', cpf: '11144477735' })] }));

		const res = await GET(ev({ cpf: '11144477735', exclude: 'eu' }));

		expect(await res.json()).toEqual({ match: null });
	});

	// Arquivada conta como duplicado (o índice único não olha `ativo`), e é justamente o caso em
	// que a tela precisa dizer outra coisa: reative em vez de recadastrar.
	it('ficha arquivada avisa, dizendo que está arquivada', async () => {
		apiFetch.mockResolvedValueOnce(
			json({ patients: [ficha({ cpf: '11144477735', ativo: false })] })
		);

		const res = await GET(ev({ cpf: '11144477735' }));

		expect((await res.json()).match).toEqual({
			id: 'p1',
			nome: 'João Souza',
			campo: 'CPF',
			ativo: false
		});
	});

	it('API recusa (401) → sem aviso (ele nunca barra o cadastro)', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 401 }));

		expect(await (await GET(ev({ cpf: '11144477735' }))).json()).toEqual({ match: null });
	});

	it('rede fora → sem aviso', async () => {
		apiFetch.mockRejectedValueOnce(new Error('down'));

		expect(await (await GET(ev({ cpf: '11144477735' }))).json()).toEqual({ match: null });
	});

	// AN-10 (HOM-013, resto): o cadastro feito SEM documento — `?nome=&nascimento=` busca pelo
	// nome na API (que não filtra por data) e ESTE endpoint recorta por nascimento igual.
	describe('duplicado por nome + nascimento', () => {
		it('busca pelo nome e devolve só quem tem o MESMO nascimento', async () => {
			apiFetch.mockResolvedValueOnce(
				json({
					patients: [
						ficha({ id: 'p1', nome: 'Mariana Alvarenga', nascimento: '1980-01-01' }),
						ficha({ id: 'p2', nome: 'Mariana Alves', nascimento: '1990-05-20' }),
						ficha({ id: 'p3', nome: 'Mariana Alvim', nascimento: null })
					]
				})
			);

			const res = await GET(ev({ nome: 'Mariana Alves', nascimento: '1990-05-20' }));

			expect(apiFetch).toHaveBeenCalledWith(
				expect.anything(),
				expect.stringContaining('q=Mariana+Alves'),
				expect.anything()
			);
			expect(await res.json()).toEqual({
				match: {
					id: 'p2',
					nome: 'Mariana Alves',
					campo: 'nome e data de nascimento',
					ativo: true
				}
			});
		});

		it('nome curto ou data torta nem consultam', async () => {
			expect(await (await GET(ev({ nome: 'Ma', nascimento: '1990-05-20' }))).json()).toEqual({
				match: null
			});
			expect(await (await GET(ev({ nome: 'Mariana', nascimento: '20/05/1990' }))).json()).toEqual({
				match: null
			});
			expect(apiFetch).not.toHaveBeenCalled();
		});

		// Nome+nascimento é a heurística de quem NÃO tem documento. Com identificação preenchida
		// ela só gastaria uma consulta a mais para dizer o que o CPF já disse.
		it('não consulta por nome quando há identificação completa', async () => {
			apiFetch.mockResolvedValueOnce(json({ patients: [] }));

			await GET(ev({ cpf: '11144477735', nome: 'Mariana Alves', nascimento: '1990-05-20' }));

			expect(apiFetch).toHaveBeenCalledTimes(1);
		});
	});
});
