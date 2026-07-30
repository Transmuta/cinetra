import { describe, expect, it } from 'vitest';
import { formatarTelefone, recebeWhatsapp, telefoneValido } from './telefone';

describe('formatarTelefone', () => {
	it('mascara o E.164 que vem do banco', () => {
		expect(formatarTelefone('+5511987654321')).toBe('(11) 98765-4321');
		expect(formatarTelefone('+551134567890')).toBe('(11) 3456-7890');
	});

	it('mascara também o que veio sem código de país', () => {
		expect(formatarTelefone('11987654321')).toBe('(11) 98765-4321');
	});

	it('devolve como veio o que não reconhece — nunca esconde o dado', () => {
		// A ficha legada tem telefone escrito de todo jeito. Melhor exibir estranho do que sumir.
		expect(formatarTelefone('ramal 22')).toBe('ramal 22');
		expect(formatarTelefone('+1 415 555 0000')).toBe('+1 415 555 0000');
	});

	it('vazio continua vazio', () => {
		expect(formatarTelefone(null)).toBeNull();
		expect(formatarTelefone('')).toBeNull();
	});
});

describe('recebeWhatsapp', () => {
	it('celular recebe', () => {
		expect(recebeWhatsapp('+5511987654321')).toBe(true);
		expect(recebeWhatsapp('11987654321')).toBe(true);
	});

	it('fixo não recebe — e é por isso que a tela avisa', () => {
		expect(recebeWhatsapp('+551134567890')).toBe(false);
		expect(recebeWhatsapp('1134567890')).toBe(false);
	});

	it('número de outro país não é celular brasileiro', () => {
		// `+1 495 555 0000` tem 11 dígitos e um "9" na terceira casa: a contagem sozinha diria que
		// sim. É o mesmo tropeço que a máscara deu com o `+1`.
		expect(recebeWhatsapp('+1 495 555 0000')).toBe(false);
	});

	it('vazio não recebe', () => {
		expect(recebeWhatsapp(null)).toBe(false);
	});
});

describe('telefoneValido', () => {
	it('celular e fixo com DDD passam', () => {
		expect(telefoneValido('(11) 98765-4321')).toBe(true);
		expect(telefoneValido('(11) 3456-7890')).toBe(true);
	});

	it('já com o 55 também passa — a borda que o cliente ingênuo barraria', () => {
		expect(telefoneValido('+5511987654321')).toBe(true);
		expect(telefoneValido('551134567890')).toBe(true);
	});

	it('curto demais não passa', () => {
		expect(telefoneValido('123')).toBe(false);
		expect(telefoneValido('11987654')).toBe(false);
	});

	it('vazio não passa — é o caso que a D6 veio cobrar', () => {
		expect(telefoneValido(null)).toBe(false);
		expect(telefoneValido('')).toBe(false);
	});

	// DIVERGE de `recebeWhatsapp` de propósito: o servidor não tem a guarda de estrangeiro, e
	// `normalizar/2` aceita 11 dígitos venham de onde vierem. Recusar aqui faria a tela barrar
	// o que o banco grava — o teste existe para essa escolha não ser desfeita sem querer.
	it('estrangeiro de 11 dígitos passa, porque o servidor o aceita', () => {
		expect(telefoneValido('+1 415 555 0000')).toBe(true);
	});
});
