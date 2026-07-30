import { describe, it, expect } from 'vitest';
import { isValidCpf } from './cpf';

// Espelho de `Api.Cpf` (AN-11 / D10): a régua é a do servidor; aqui ela só chega antes da
// viagem — mesmo desenho do `telefoneValido` × `TelObrigatorio`.
describe('isValidCpf', () => {
	it('aceita CPF válido, com ou sem máscara', () => {
		expect(isValidCpf('390.533.447-05')).toBe(true);
		expect(isValidCpf('39053344705')).toBe(true);
		expect(isValidCpf('123.456.789-09')).toBe(true);
	});

	it('reprova dígito verificador errado', () => {
		expect(isValidCpf('123.456.789-00')).toBe(false);
		expect(isValidCpf('390.533.447-06')).toBe(false);
	});

	it('reprova sequência repetida mesmo com DV aritmeticamente correto', () => {
		expect(isValidCpf('111.111.111-11')).toBe(false);
		expect(isValidCpf('000.000.000-00')).toBe(false);
	});

	it('reprova tamanho errado e vazio', () => {
		expect(isValidCpf('1234567890')).toBe(false);
		expect(isValidCpf('')).toBe(false);
	});
});
