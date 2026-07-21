import { describe, it, expect } from 'vitest';
import { relativeTime, notificationHref } from './notifications';

describe('relativeTime', () => {
	const now = new Date('2026-07-21T12:00:00Z');

	it('menos de 1 min → "agora"', () => {
		expect(relativeTime('2026-07-21T11:59:30Z', now)).toBe('agora');
	});

	it('minutos', () => {
		expect(relativeTime('2026-07-21T11:45:00Z', now)).toBe('há 15 min');
	});

	it('horas', () => {
		expect(relativeTime('2026-07-21T09:00:00Z', now)).toBe('há 3 h');
	});

	it('ontem', () => {
		expect(relativeTime('2026-07-20T10:00:00Z', now)).toBe('ontem');
	});

	it('dias na mesma semana', () => {
		expect(relativeTime('2026-07-18T10:00:00Z', now)).toBe('há 3 dias');
	});

	it('mais de uma semana → data', () => {
		// Além de 7 dias cai na data localizada — só afirmamos que não é um "há N".
		expect(relativeTime('2026-07-01T10:00:00Z', now)).not.toContain('há');
	});
});

describe('notificationHref', () => {
	it('eventos de agenda levam à agenda', () => {
		expect(notificationHref('appointment_scheduled')).toBe('/agenda');
		expect(notificationHref('appointment_rescheduled')).toBe('/agenda');
		expect(notificationHref('appointment_canceled')).toBe('/agenda');
	});

	it('vaga livre leva à fila', () => {
		expect(notificationHref('slot_opened')).toBe('/fila');
	});

	it('novo membro leva à equipe', () => {
		expect(notificationHref('member_joined')).toBe('/configuracoes/equipe');
	});
});
