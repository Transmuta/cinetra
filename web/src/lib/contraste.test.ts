import { describe, expect, it } from 'vitest';
import { AVATAR_PALETTE, avatarStyle } from './avatar';
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

/** O sage da marca, que é a única exceção registrada da paleta de avatar (ver `avatarStyle`). */
const SAGE = '#7FA59A';

/** A cor de texto que o `avatarStyle` de fato emite — é ela que a tela mostra. */
function textoDoAvatar(fundo: string): string {
	const m = /color:(#[0-9a-f]{6})/i.exec(avatarStyle(fundo));
	if (!m) throw new Error(`avatarStyle('${fundo}') não emitiu cor de texto`);
	return m[1];
}

describe('paletas categóricas passam 4,5:1 com o texto escolhido', () => {
	/**
	 * Mede o que o `avatarStyle` **emite**, não o que o `textoSobre` escolheria. A diferença passou
	 * a existir com a exceção do sage: `textoSobre` devolveria o escuro (6,46), então um teste
	 * escrito sobre ele continuaria verde enquanto a tela mostra branco a 2,71. Medir a função que
	 * a marcação usa é o que impede o teste de concordar com uma realidade que mudou.
	 */
	it.each(AVATAR_PALETTE.filter((c) => c !== SAGE))('avatar %s', (cor) => {
		const texto = textoDoAvatar(cor);
		const r = razaoDeContraste(texto, cor);
		expect(
			r,
			`avatar (${cor}): o avatarStyle emitiu ${texto}, que dá ${r.toFixed(2)} — abaixo de ${PISO}`
		).toBeGreaterThanOrEqual(PISO);
	});

	/**
	 * O sage — **EXCEÇÃO REGISTRADA** (ADR-020 estendida ao avatar, débito D-17).
	 *
	 * Branco sobre `#7FA59A` mede 2,71:1. Está aqui cravado, e não escondido, para que a exceção
	 * seja um fato medido e versionado. O motivo é consistência: o botão primário já é branco sobre
	 * este mesmo sage, e o avatar com texto escuro poria dois tratamentos da mesma cor lado a lado.
	 */
	it('avatar sage usa branco por decisão, a 2,71:1 (exceção registrada)', () => {
		expect(AVATAR_PALETTE, 'o sage precisa continuar na paleta para esta exceção fazer sentido').toContain(
			SAGE
		);
		expect(textoDoAvatar(SAGE), 'o texto sobre o sage é branco, por decisão').toBe(TEXTO_CLARO);

		const r = razaoDeContraste(TEXTO_CLARO, SAGE);
		expect(r).toBeGreaterThan(2.6);
		expect(
			r,
			`branco sobre o sage subiu para ${r.toFixed(2)}. Se passou de ${PISO}, a exceção morreu: ` +
				`tire o sage do SEMPRE_BRANCO em avatar.ts e devolva esta cor ao bloco de cima.`
		).toBeLessThan(PISO);
	});

	/** A exceção é do tamanho de UMA cor: as outras seis não podem tê-la herdado. */
	it('nenhuma outra cor da paleta virou branco de graça', () => {
		for (const cor of AVATAR_PALETTE.filter((c) => c !== SAGE)) {
			expect(textoDoAvatar(cor), `${cor} deve seguir o textoSobre, não a exceção`).toBe(
				textoSobre(cor)
			);
		}
	});

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
