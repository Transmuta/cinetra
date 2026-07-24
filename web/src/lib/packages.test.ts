import { describe, it, expect } from 'vitest';
import { statusLabel, issueLabel, DOW_LABELS } from './packages';

describe('statusLabel', () => {
	it('traduz cada status', () => {
		expect(statusLabel('ativo')).toBe('Ativo');
		expect(statusLabel('pausado')).toBe('Pausado');
		expect(statusLabel('cancelado')).toBe('Cancelado');
		expect(statusLabel('concluido')).toBe('Concluído');
	});

	it('desconhecido cai no próprio valor', () => {
		expect(statusLabel('outro' as never)).toBe('outro');
	});
});

describe('issueLabel', () => {
	it('ok é silencioso (string vazia)', () => {
		expect(issueLabel('ok')).toBe('');
	});

	it('os bloqueantes e o join têm rótulo', () => {
		expect(issueLabel('fora_expediente')).toMatch(/expediente/i);
		expect(issueLabel('conflito')).toMatch(/conflito/i);
		expect(issueLabel('cheia')).toMatch(/cheia/i);
		expect(issueLabel('join')).toMatch(/turma/i);
		expect(issueLabel('feriado')).toMatch(/feriado/i);
	});
});

describe('DOW_LABELS', () => {
	it('0 é domingo, 6 é sábado (convenção do projeto)', () => {
		expect(DOW_LABELS[0]).toBe('Dom');
		expect(DOW_LABELS[6]).toBe('Sáb');
	});
});
