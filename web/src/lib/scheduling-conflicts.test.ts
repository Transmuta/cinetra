import { describe, it, expect } from 'vitest';
import {
	parseFutureConflicts,
	diaCurto,
	motivoLabel,
	resumoConflitos,
	type FutureConflict
} from './scheduling-conflicts';

function conflito(over: Partial<FutureConflict> = {}): FutureConflict {
	return {
		appointment_id: 'a1',
		date: '2026-07-20',
		hora: '14:00',
		reason: 'fora_do_expediente',
		periods_depois: [['08:00', '12:00']],
		professional: { id: 'p1', nome: 'Dra. Bea' },
		patients: ['Caio'],
		...over
	};
}

describe('parseFutureConflicts', () => {
	it('lê o meta do 409 quando o code é o do conflito futuro', () => {
		const r = parseFutureConflicts('future_conflicts', {
			conflicts: [conflito()],
			truncado: false
		});

		expect(r?.conflicts).toHaveLength(1);
		expect(r?.truncado).toBe(false);
	});

	it('outro code devolve null — a tela mostra toast, não o modal', () => {
		expect(parseFutureConflicts('schedule_conflict', { conflicts: [conflito()] })).toBeNull();
		expect(parseFutureConflicts(undefined, undefined)).toBeNull();
	});

	it('meta sem lista, ou com lista vazia, devolve null', () => {
		expect(parseFutureConflicts('future_conflicts', {})).toBeNull();
		expect(parseFutureConflicts('future_conflicts', { conflicts: [] })).toBeNull();
	});

	it('descarta linha malformada em vez de desenhar linha vazia', () => {
		const r = parseFutureConflicts('future_conflicts', {
			conflicts: [conflito(), { appointment_id: 'x' }, null, 'lixo']
		});

		expect(r?.conflicts).toHaveLength(1);
	});

	it('propaga o corte do teto do servidor', () => {
		const r = parseFutureConflicts('future_conflicts', {
			conflicts: [conflito()],
			truncado: true
		});

		expect(r?.truncado).toBe(true);
	});
});

describe('rótulos', () => {
	it('data curta, sem o ano', () => {
		expect(diaCurto('2026-07-20')).toBe('20/07');
		expect(diaCurto('lixo')).toBe('lixo');
	});

	it('o motivo nomeia a janela nova quando existe', () => {
		expect(motivoLabel(conflito())).toBe('Fora do novo expediente (08:00–12:00)');
	});

	it('dia fechado tem frase própria', () => {
		expect(motivoLabel(conflito({ reason: 'sem_atendimento', periods_depois: [] }))).toBe(
			'Sem atendimento nesse dia'
		);
	});

	it('fora do expediente sem janela não vira parêntese vazio', () => {
		expect(motivoLabel(conflito({ periods_depois: [] }))).toBe('Fora do novo expediente');
	});

	it('o resumo conta e avisa quando a lista foi cortada', () => {
		expect(resumoConflitos({ conflicts: [conflito()], truncado: false })).toBe(
			'1 agendamento futuro ficaria fora do expediente'
		);
		expect(resumoConflitos({ conflicts: [conflito(), conflito()], truncado: false })).toBe(
			'2 agendamentos futuros ficariam fora do expediente'
		);
		expect(resumoConflitos({ conflicts: [conflito()], truncado: true })).toBe(
			'1 agendamento futuro ficaria fora do expediente (e possivelmente mais)'
		);
	});
});
