/**
 * Contraste para as paletas **categóricas** — as cores que não vêm dos tokens do tema: avatar de
 * pessoa, cor do tipo de atendimento, nível de prioridade da fila.
 *
 * Por que isto existe: essas paletas pintavam o fundo e o texto ia `text-white` cravado. Medido
 * (doc 83): das 7 cores de avatar, **5 reprovam** com branco — o âmbar `#E69F00` fica em 2,25:1 —
 * e não existe uma cor de texto única que sirva para todas (duas pedem branco, cinco pedem
 * escuro). Escurecer a paleta não é opção: ela é validada pelo `one_of` de
 * `Api.Directory.AppointmentType`, então o hex é contrato com o servidor (débito D-3).
 *
 * A saída é escolher o texto **por cor de fundo**, que é o que `textoSobre` faz.
 */

/** Preto-azulado do app (`--mv-text` do tema claro). Fixo: o fundo categórico não muda com o tema. */
export const TEXTO_ESCURO = '#161a1e';
export const TEXTO_CLARO = '#ffffff';

function canais(hex: string): [number, number, number] {
	const c = hex.replace('#', '').trim();
	return [0, 2, 4].map((i) => parseInt(c.slice(i, i + 2), 16)) as [number, number, number];
}

/** Luminância relativa (WCAG 2.x). */
function luminancia(hex: string): number {
	const ajusta = (v: number) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
	const [r, g, b] = canais(hex).map((c) => ajusta(c / 255));
	return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** Razão de contraste entre duas cores opacas. 1 = iguais, 21 = preto sobre branco. */
export function razaoDeContraste(a: string, b: string): number {
	const [x, y] = [luminancia(a), luminancia(b)];
	return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

/**
 * A cor de texto que contrasta MAIS com o fundo dado — escuro ou claro, o melhor dos dois.
 *
 * Não é "escolha um piso e aceite": para uma paleta categórica de cor viva, o melhor dos dois é
 * o único critério que funciona em todas as cores de uma vez. Se nem o melhor bater 4,5:1, o
 * problema é a **cor de fundo**, e é isso que `contraste.test.ts` reprova — não este cálculo.
 */
export function textoSobre(fundo: string): string {
	return razaoDeContraste(TEXTO_ESCURO, fundo) >= razaoDeContraste(TEXTO_CLARO, fundo)
		? TEXTO_ESCURO
		: TEXTO_CLARO;
}
