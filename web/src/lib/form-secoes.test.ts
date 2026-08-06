import { describe, it, expect } from 'vitest';
import { totalDeChaves, totalPreenchido, secaoCorrente } from './form-secoes';

const SECOES = [
	{ id: 'ident', total: 8 },
	{ id: 'contato', total: 8 },
	{ id: 'emergencia', total: 3 }
];

describe('progresso do formulário', () => {
	it('o denominador é a soma dos campos de todas as seções', () => {
		expect(totalDeChaves(SECOES)).toBe(19);
	});

	it('o numerador soma as contagens por seção', () => {
		expect(totalPreenchido({ ident: 5, contato: 2, emergencia: 0 })).toBe(7);
	});

	it('formulário em branco conta zero, não NaN', () => {
		expect(totalPreenchido({})).toBe(0);
	});
});

describe('secaoCorrente', () => {
	/**
	 * A folga é a razão de existir da função, e ela antecipa a troca: a linha de leitura fica 56px
	 * ABAIXO do topo, que é a altura do cabeçalho fixo. Sem isso a seção só viraria ativa quando o
	 * título dela já estivesse escondido atrás do cabeçalho — a coluna lateral ficaria sempre um
	 * passo atrás da leitura.
	 */
	it('a seção ainda ABAIXO do topo já conta, se estiver dentro da folga', () => {
		const topos = [
			{ id: 'ident', topoRelativo: -200 },
			{ id: 'contato', topoRelativo: 40 } // 40 < 56: já cruzou a linha de leitura
		];

		expect(secaoCorrente(topos)).toBe('contato');
	});

	it('mas fora da folga, não — senão a coluna andaria antes da leitura', () => {
		const topos = [
			{ id: 'ident', topoRelativo: -200 },
			{ id: 'contato', topoRelativo: 80 }
		];

		expect(secaoCorrente(topos)).toBe('ident');
	});

	it('vale a ÚLTIMA que passou, não a primeira', () => {
		const topos = [
			{ id: 'ident', topoRelativo: -600 },
			{ id: 'contato', topoRelativo: -300 },
			{ id: 'emergencia', topoRelativo: -20 }
		];

		expect(secaoCorrente(topos)).toBe('emergencia');
	});

	/** No topo da página nenhuma passou da linha, e a coluna precisa marcar alguma mesmo assim. */
	it('no topo, cai na primeira', () => {
		const topos = [
			{ id: 'ident', topoRelativo: 100 },
			{ id: 'contato', topoRelativo: 900 }
		];

		expect(secaoCorrente(topos)).toBe('ident');
	});

	it('lista vazia não estoura', () => {
		expect(secaoCorrente([])).toBe('');
	});
});
