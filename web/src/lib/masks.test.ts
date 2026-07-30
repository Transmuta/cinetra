import { describe, it, expect } from 'vitest';
import { maskCpf, maskTel, maskCep, maskCnpj, maskAno, maskUf, maskMy } from './masks';

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

describe('maskCnpj', () => {
	it('formata numérico e alfanumérico progressivamente', () => {
		expect(maskCnpj('123')).toBe('12.3');
		expect(maskCnpj('12345678000190')).toBe('12.345.678/0001-90');
		expect(maskCnpj('12abc678000190')).toBe('12.ABC.678/0001-90');
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

describe('maskMy', () => {
	it('formata MM/AAAA progressivamente', () => {
		expect(maskMy('12')).toBe('12');
		expect(maskMy('122028')).toBe('12/2028');
		expect(maskMy('12/2028extra')).toBe('12/2028');
	});
});
