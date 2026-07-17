import { describe, it, expect } from 'vitest';
import { maskCpf, maskTel, maskCep, maskAno, maskUf } from './masks';

describe('maskCpf', () => {
	it('formata progressivamente e trunca em 11 dígitos', () => {
		expect(maskCpf('123')).toBe('123');
		expect(maskCpf('1234')).toBe('123.4');
		expect(maskCpf('1234567')).toBe('123.456.7');
		expect(maskCpf('12345678901')).toBe('123.456.789-01');
		expect(maskCpf('123.456.789-01extra')).toBe('123.456.789-01');
	});
});

describe('maskTel', () => {
	it('celular (11) e fixo (10)', () => {
		expect(maskTel('')).toBe('');
		expect(maskTel('11')).toBe('(11');
		expect(maskTel('1198')).toBe('(11) 98');
		expect(maskTel('11981234567')).toBe('(11) 98123-4567');
		expect(maskTel('1132123456')).toBe('(11) 3212-3456');
	});
});

describe('maskCep', () => {
	it('00000-000', () => {
		expect(maskCep('01310')).toBe('01310');
		expect(maskCep('01310100')).toBe('01310-100');
		expect(maskCep('013101009')).toBe('01310-100');
	});
});

describe('maskAno / maskUf', () => {
	it('ano: 4 dígitos', () => {
		expect(maskAno('20a10x')).toBe('2010');
	});
	it('uf: 2 letras maiúsculas', () => {
		expect(maskUf('sp')).toBe('SP');
		expect(maskUf('s2p3x')).toBe('SP');
	});
});
