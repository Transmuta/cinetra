import { describe, it, expect } from 'vitest';
import { dropMinutes, passouLimiar } from './agenda-drag';

const range = { start: 480, end: 1080 };
const PPM = 1.05;
const PAD = 14;
const DUR = 50;

// `bodyTop` é o topo do corpo da coluna na tela; `y` é o clientY do ponteiro.
const at = (y: number) => dropMinutes(y, 100, range, PPM, PAD, DUR);

describe('dropMinutes', () => {
	it('mapeia o topo do corpo para o início da faixa', () => {
		// y = bodyTop + pad → minuto = range.start.
		expect(at(114)).toBe(480);
	});

	it('faz snap de 15 minutos', () => {
		// ~495 min: 495 é múltiplo de 15, então fica; um valor vizinho arredonda para ele.
		expect(at(114 + 15 * PPM)).toBe(495);
		expect(at(114 + 20 * PPM)).toBe(495); // 500 → 495
	});

	it('clampa no início (não sobe acima da faixa)', () => {
		expect(at(0)).toBe(480);
	});

	it('clampa no fim menos a duração (o bloco cabe inteiro)', () => {
		// Muito abaixo: teto = end - dur = 1030.
		expect(at(100000)).toBe(1030);
	});

	it('grabDy: o ponto agarrado do bloco fica sob o ponteiro (não o topo)', () => {
		// y=240 dá 600 min sem grab (bem dentro da faixa, longe do clamp). Agarrado 30px
		// abaixo do topo do bloco, o TOPO sobe grabDy px → ~28,6 min → snap 570.
		expect(dropMinutes(240, 100, range, PPM, PAD, DUR, 15, 30)).toBe(570);
		// grabDy = 0 mantém o comportamento antigo (topo no ponteiro).
		expect(dropMinutes(240, 100, range, PPM, PAD, DUR, 15, 0)).toBe(600);
	});
});

describe('passouLimiar', () => {
	it('abaixo do limiar é clique, não arraste', () => {
		expect(passouLimiar(2, -3)).toBe(false);
		expect(passouLimiar(4, 4)).toBe(false);
	});

	it('acima do limiar em qualquer eixo é arraste', () => {
		expect(passouLimiar(5, 0)).toBe(true);
		expect(passouLimiar(0, -6)).toBe(true);
	});
});
