import { describe, it, expect } from 'vitest';
import { normalizeCnpj, maskCnpj, isValidCnpj } from './cnpj';

// Vetores de ouro (conferidos pelo módulo 11 com ASCII − 48):
//   12ABC34501DE35 → alfanumérico válido (exemplo canônico do Serpro)
//   11222333000181 → numérico clássico válido (retrocompatível)

describe('normalizeCnpj', () => {
	it('mantém só [0-9A-Z] e sobe para maiúsculas', () => {
		expect(normalizeCnpj('12.abc.345/01de-35')).toBe('12ABC34501DE35');
		expect(normalizeCnpj(' 11.222.333/0001-81 ')).toBe('11222333000181');
	});
});

describe('maskCnpj', () => {
	it('aplica a máscara XX.XXX.XXX/XXXX-XX', () => {
		expect(maskCnpj('12ABC34501DE35')).toBe('12.ABC.345/01DE-35');
		expect(maskCnpj('11222333000181')).toBe('11.222.333/0001-81');
	});

	it('formata entradas parciais e trunca em 14', () => {
		expect(maskCnpj('12A')).toBe('12.A');
		expect(maskCnpj('12ABC345')).toBe('12.ABC.345');
		expect(maskCnpj('12ABC34501DE3599')).toBe('12.ABC.345/01DE-35');
		expect(maskCnpj('')).toBe('');
	});
});

describe('isValidCnpj', () => {
	it('aceita alfanumérico e numérico válidos, com ou sem máscara', () => {
		expect(isValidCnpj('12.ABC.345/01DE-35')).toBe(true);
		expect(isValidCnpj('12abc34501de35')).toBe(true);
		expect(isValidCnpj('11.222.333/0001-81')).toBe(true);
	});

	it('rejeita DV errado, tamanho errado e o CNPJ vazio', () => {
		expect(isValidCnpj('12ABC34501DE34')).toBe(false);
		expect(isValidCnpj('11222333000182')).toBe(false);
		expect(isValidCnpj('12ABC34501DE3')).toBe(false);
		expect(isValidCnpj('00000000000000')).toBe(false);
		expect(isValidCnpj('')).toBe(false);
	});
});
