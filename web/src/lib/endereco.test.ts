import { describe, it, expect } from 'vitest';
import { linhasDeEndereco, enderecoEmLinha, type Endereco } from './endereco';

const completo: Endereco = {
	cep: '01310-100',
	endereco: 'Av. Paulista',
	numero: '1000',
	complemento: 'Sala 42',
	bairro: 'Bela Vista',
	cidade: 'São Paulo',
	uf: 'SP'
};

describe('linhasDeEndereco', () => {
	it('três linhas: o lugar, o complemento e a localidade', () => {
		expect(linhasDeEndereco(completo)).toEqual([
			'Av. Paulista, 1000',
			'Sala 42',
			'Bela Vista · São Paulo/SP · CEP 01310-100'
		]);
	});

	// Medido no browser: colado ao logradouro por " — ", um endereço real quebra na coluna de
	// 256px do sidebar e o travessão ABRE a linha de baixo. Nenhuma linha começa por separador.
	it('o complemento tem linha própria — nada de travessão sobrando', () => {
		const linhas = linhasDeEndereco(completo);
		expect(linhas.some((l) => l.startsWith('—'))).toBe(false);
		expect(linhas).toContain('Sala 42');
	});

	// A regra inteira deste módulo: o campo vazio some, e o separador dele vai junto. Sem isso
	// uma clínica que só preencheu a cidade lê "— , — - SP" (é o defeito que a tela de leitura
	// da clínica já tratava à mão — e que o sidebar não tratava de jeito nenhum).
	it('pula o que não existe, sem separador órfão', () => {
		expect(linhasDeEndereco({ endereco: 'Rua X', cidade: 'Santos', uf: 'SP' })).toEqual([
			'Rua X',
			'Santos/SP'
		]);
	});

	it('só a cidade: nada de "/" pendurado', () => {
		expect(linhasDeEndereco({ cidade: 'Santos' })).toEqual(['Santos']);
	});

	it('só o número: nada de vírgula pendurada', () => {
		expect(linhasDeEndereco({ numero: '100' })).toEqual(['100']);
	});

	it('endereço vazio não vira linha nenhuma', () => {
		expect(linhasDeEndereco({})).toEqual([]);
		expect(linhasDeEndereco({ endereco: '   ', uf: '' })).toEqual([]);
	});

	// O CEP é guardado como a pessoa digitou (o formulário mascara), mas quem escreve pela API
	// pode mandar os oito dígitos crus — e "01310100" na tela lê como número de protocolo.
	it('o CEP sai mascarado e rotulado, venha como vier', () => {
		expect(linhasDeEndereco({ cep: '01310100' })).toEqual(['CEP 01310-100']);
		expect(linhasDeEndereco({ cep: '01310-100' })).toEqual(['CEP 01310-100']);
	});

	it('complemento sem rua ainda é o lugar', () => {
		expect(linhasDeEndereco({ complemento: 'Fundos' })).toEqual(['Fundos']);
	});
});

describe('enderecoEmLinha', () => {
	it('junta as linhas com ponto médio', () => {
		expect(enderecoEmLinha(completo)).toBe(
			'Av. Paulista, 1000 · Sala 42 · Bela Vista · São Paulo/SP · CEP 01310-100'
		);
	});

	// String vazia, e não "—": quem desenha a tela decide como dizer "não tem".
	it('sem nada preenchido é string vazia', () => {
		expect(enderecoEmLinha({})).toBe('');
	});
});
