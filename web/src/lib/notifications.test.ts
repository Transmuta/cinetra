import { describe, it, expect } from 'vitest';
import {
	relativeTime,
	notificationHref,
	notificationsHref,
	onlyUnreadFrom,
	type NotificationKind
} from './notifications';

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
	const href = (kind: NotificationKind, data: Record<string, unknown> = {}) =>
		notificationHref({ kind, data });

	it('eventos de agenda levam à agenda', () => {
		expect(href('appointment_scheduled')).toBe('/agenda');
		expect(href('appointment_rescheduled')).toBe('/agenda');
		expect(href('appointment_canceled')).toBe('/agenda');
		// A2 (doc 41 etapa 5)
		expect(href('appointment_missed')).toBe('/agenda');
		expect(href('participant_added')).toBe('/agenda');
	});

	// #56: o motivo do item existir. Sem a data, "seu paciente de quinta foi remarcado" abria a
	// agenda de HOJE e a pessoa navegava até lá na mão.
	it('quando a notificação traz a data, a agenda abre nela', () => {
		expect(href('appointment_rescheduled', { date: '2026-08-13' })).toBe('/agenda?date=2026-08-13');
		expect(href('session_soon', { date: '2026-08-13' })).toBe('/agenda?date=2026-08-13');
		expect(href('daily_digest', { date: '2026-08-14' })).toBe('/agenda?date=2026-08-14');
	});

	// `data` é jsonb livre; o destino de navegação não confia nele sem olhar.
	it('data com formato inválido é ignorada', () => {
		expect(href('appointment_canceled', { date: 'amanhã' })).toBe('/agenda');
		expect(href('appointment_canceled', { date: 42 })).toBe('/agenda');
	});

	it('a massa por pacote não tem um dia só, então abre no padrão', () => {
		expect(href('package_bulk_adjusted', { afetadas: 3 })).toBe('/agenda');
	});

	it('vaga livre leva à fila, e urgente leva à fila já filtrada', () => {
		expect(href('slot_opened')).toBe('/fila');
		expect(href('waitlist_urgent')).toBe('/fila?prio=urgente');
	});

	it('governança de membros leva à equipe', () => {
		expect(href('member_joined')).toBe('/configuracoes/equipe');
		expect(href('member_removed')).toBe('/configuracoes/equipe');
		expect(href('role_changed')).toBe('/configuracoes/equipe');
	});
});

// O contrato do filtro da caixa (Todas / Não lidas). Ele atravessa TRÊS lugares — a sidebar
// que monta o link, o `load` que lê a URL e o resgate da página-além-do-fim — e estava escrito
// à mão nos três. Uma renomeação em dois deles e o terceiro para de filtrar EM SILÊNCIO: o
// link continua válido, a tela continua abrindo, só não filtra mais.
describe('filtro da caixa', () => {
	it('o href de cada filtro', () => {
		expect(notificationsHref(false)).toBe('/notificacoes');
		expect(notificationsHref(true)).toBe('/notificacoes?filtro=nao-lidas');
	});

	it('lê o filtro da query string', () => {
		expect(onlyUnreadFrom(new URLSearchParams('filtro=nao-lidas'))).toBe(true);
		expect(onlyUnreadFrom(new URLSearchParams(''))).toBe(false);
	});

	// Valor desconhecido não é erro: degrada para "todas", que é o estado neutro da tela.
	it('valor estranho cai em "todas"', () => {
		expect(onlyUnreadFrom(new URLSearchParams('filtro=xpto'))).toBe(false);
	});

	// O link do filtro NÃO carrega `?page=`: a página 3 de "Todas" não é a página 3 de
	// "Não lidas", e herdar o número levaria a um beco (que o load teria de resgatar).
	it('o href não carrega página', () => {
		expect(notificationsHref(true)).not.toContain('page');
	});
});
