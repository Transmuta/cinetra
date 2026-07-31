import { describe, it, expect } from 'vitest';
import { initials } from './format';

describe('initials', () => {
	it('duas primeiras iniciais, maiúsculas', () => {
		expect(initials('Ana Paula Souza')).toBe('AP');
	});

	it('nome único → uma inicial', () => {
		expect(initials('joão')).toBe('J');
	});

	it('tolera espaços extras', () => {
		expect(initials('  Marina  Alves  ')).toBe('MA');
	});

	/**
	 * O título não identifica ninguém — numa clínica com três doutoras, `D?` é o mesmo avatar três
	 * vezes. E `nome_exibicao` é justamente o campo onde se escreve "Dra. Marina", então o prefixo
	 * chega por desenho, não por acidente.
	 *
	 * Havia DUAS implementações discordando (doc 93 §A-4): esta e uma função local em
	 * `/relatorios` que sombreava o import. O mesmo profissional tinha duas iniciais no mesmo
	 * produto — e como o avatar é colorido por `cor_indice`, a cor batia e só o texto mudava, que
	 * é pior que divergirem os dois.
	 */
	describe('título de tratamento', () => {
		it('"Dra. Ana Silva" → AS (o D do título não conta)', () => {
			expect(initials('Dra. Ana Silva')).toBe('AS');
		});

		it('"Dr. João Souza" → JS', () => {
			expect(initials('Dr. João Souza')).toBe('JS');
		});

		it('sem título continua igual', () => {
			expect(initials('Ana Silva')).toBe('AS');
		});

		it('o corte é insensível a caixa', () => {
			expect(initials('DRA. Ana Silva')).toBe('AS');
		});

		it('só tira o título quando ele vem com ponto — "Draco Alves" continua DA', () => {
			expect(initials('Draco Alves')).toBe('DA');
		});

		it('nome que é só o título não vira vazio', () => {
			expect(initials('Dra.')).toBe('D');
		});
	});
});
