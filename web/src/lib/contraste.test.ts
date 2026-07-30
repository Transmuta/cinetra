import { describe, expect, it } from 'vitest';
import { AVATAR_PALETTE } from './avatar';
import { TYPE_COLORS } from './appointment-types';
import { PRIORITY_META, PRIORITY_ORDER } from './waitlist';
import { razaoDeContraste, textoSobre, TEXTO_CLARO, TEXTO_ESCURO } from './contraste';

/**
 * Tripwire das paletas **categóricas** (avatar, tipo de atendimento, prioridade).
 *
 * O par `contraste.test.ts` do `styles/` cuida dos tokens do tema; este cuida das cores que vêm
 * de lista, e que ninguém media: 5 das 7 cores de avatar reprovavam com o `text-white` cravado
 * que estava em ~20 telas (doc 83).
 *
 * O contrato é: **para toda cor da paleta, `textoSobre` devolve um texto que passa 4,5:1**. Uma
 * cor nova que não sirva a nenhum dos dois textos reprova aqui — que é o momento certo de
 * descobrir, e não em produção.
 */

const PISO = 4.5;

function checa(nome: string, fundo: string) {
	const texto = textoSobre(fundo);
	const r = razaoDeContraste(texto, fundo);
	expect(
		r,
		`${nome} (${fundo}): melhor texto é ${texto} e dá ${r.toFixed(2)} — nem escuro nem branco ` +
			`alcançam ${PISO}, então a COR precisa mudar`
	).toBeGreaterThanOrEqual(PISO);
}

describe('paletas categóricas passam 4,5:1 com o texto escolhido', () => {
	it.each(AVATAR_PALETTE)('avatar %s', (cor) => checa('avatar', cor));

	it.each(TYPE_COLORS)('tipo de atendimento %s', (cor) => checa('tipo', cor));

	it.each(PRIORITY_ORDER)('prioridade %s', (nivel) =>
		checa(`prioridade ${nivel}`, PRIORITY_META[nivel].color)
	);
});

describe('textoSobre', () => {
	it('escolhe escuro no fundo claro e branco no fundo escuro', () => {
		expect(textoSobre('#ffffff')).toBe(TEXTO_ESCURO);
		expect(textoSobre('#000000')).toBe(TEXTO_CLARO);
	});

	it('tolera hex minúsculo, maiúsculo e com espaço', () => {
		expect(textoSobre('#E69F00')).toBe(textoSobre('#e69f00'));
		expect(textoSobre(' #E69F00 ')).toBe(textoSobre('#E69F00'));
	});

	it('razaoDeContraste é simétrica e ancorada', () => {
		expect(razaoDeContraste('#000000', '#ffffff')).toBeCloseTo(21, 1);
		expect(razaoDeContraste('#ffffff', '#000000')).toBeCloseTo(21, 1);
		expect(razaoDeContraste('#123456', '#123456')).toBeCloseTo(1, 5);
	});
});
