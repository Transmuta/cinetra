import { describe, it, expect, vi, afterEach } from 'vitest';
import { criarCep, type CamposDeEndereco } from './cep.svelte';

afterEach(() => vi.restoreAllMocks());

function campos(over: Partial<CamposDeEndereco> = {}): CamposDeEndereco {
	return { cep: '', endereco: '', bairro: '', cidade: '', uf: '', ...over };
}

function respondeCom(body: unknown, status = 200) {
	return vi
		.spyOn(globalThis, 'fetch')
		.mockResolvedValue(new Response(JSON.stringify(body), { status }));
}

const SP = { endereco: 'Av. Paulista', bairro: 'Bela Vista', cidade: 'São Paulo', uf: 'SP' };

describe('criarCep', () => {
	it('CEP incompleto não consulta — nem sai do status nulo', async () => {
		const f = vi.spyOn(globalThis, 'fetch');
		const cep = criarCep(campos());

		await cep.consultar('0131');

		expect(f).not.toHaveBeenCalled();
		expect(cep.status).toBeNull();
	});

	it('CEP completo preenche endereço, bairro, cidade e UF', async () => {
		respondeCom(SP);
		const f = campos();
		const cep = criarCep(f);

		await cep.consultar('01310-100');

		expect(cep.status).toBe('ok');
		expect(f).toMatchObject(SP);
	});

	it('404 vira "notfound" e NÃO mexe no que já estava digitado', async () => {
		respondeCom({}, 404);
		const f = campos({ endereco: 'Rua digitada à mão' });
		const cep = criarCep(f);

		await cep.consultar('99999-999');

		expect(cep.status).toBe('notfound');
		expect(f.endereco).toBe('Rua digitada à mão');
	});

	it('campo vazio na resposta não apaga o que a pessoa preencheu', async () => {
		respondeCom({ ...SP, endereco: '' });
		const f = campos({ endereco: 'Rua digitada à mão' });
		const cep = criarCep(f);

		await cep.consultar('01310-100');

		expect(f.endereco).toBe('Rua digitada à mão');
		expect(f.cidade).toBe('São Paulo');
	});

	/**
	 * O caso que a guarda existe para cobrir, e o único difícil: corrigir o último dígito dispara
	 * duas consultas, e **a primeira pode responder depois da segunda**. Sem comparar o CEP que
	 * voltou com o último pedido, a resposta velha sobrescreve o endereço certo — e o campo passa
	 * a mostrar a rua de um CEP que a pessoa já corrigiu.
	 */
	it('resposta ATRASADA de um CEP antigo não sobrescreve a do CEP novo', async () => {
		let soltarPrimeira: (v: Response) => void = () => {};
		const primeira = new Promise<Response>((r) => (soltarPrimeira = r));

		vi.spyOn(globalThis, 'fetch')
			.mockImplementationOnce(() => primeira)
			.mockResolvedValueOnce(
				new Response(JSON.stringify({ ...SP, endereco: 'Rua do CEP NOVO' }), { status: 200 })
			);

		const f = campos();
		const cep = criarCep(f);

		const antiga = cep.consultar('01310-100');
		await cep.consultar('04567-000'); // a segunda resolve primeiro

		expect(f.endereco).toBe('Rua do CEP NOVO');

		soltarPrimeira(
			new Response(JSON.stringify({ ...SP, endereco: 'Rua do CEP VELHO' }), { status: 200 })
		);
		await antiga;

		expect(f.endereco).toBe('Rua do CEP NOVO');
	});

	it('aoDigitar mascara o campo antes de consultar', async () => {
		respondeCom(SP);
		const f = campos();
		const cep = criarCep(f);

		cep.aoDigitar({
			currentTarget: { value: '01310100' }
		} as Event & { currentTarget: HTMLInputElement });

		expect(f.cep).toBe('01310-100');
	});
});
