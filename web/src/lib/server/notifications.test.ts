import { describe, it, expect, vi, beforeEach } from 'vitest';
import { contrato, exigirCampos, primeiro } from '$lib/testing/contrato';
import type { NotificationsData } from '$lib/notifications';

const m = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => m);

const mut = vi.hoisted(() => ({ mutate: vi.fn() }));
vi.mock('./mutate', () => mut);

import {
	fetchNotifications,
	fetchUnreadCount,
	markNotificationRead,
	markAllNotificationsRead,
	clearAllNotifications
} from './notifications';

const event = {} as never;

function res(status: number, body?: unknown) {
	return { ok: status >= 200 && status < 300, status, json: async () => body };
}

beforeEach(() => {
	m.apiFetch.mockReset();
	mut.mutate.mockReset();
});

// Os corpos vêm de `contratos/bff/notificacoes.json`, gravado pela API de verdade (doc 101, A2).
const caixa = contrato<NotificationsData>('notificacoes', 'caixa');
const badge = contrato<{ unread: number }>('notificacoes', 'badge');

describe('fetchNotifications', () => {
	it('200 → devolve os dados', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, caixa));

		const out = await fetchNotifications(event);
		expect(out).toEqual({ status: 200, data: caixa });
		expect(m.apiFetch.mock.calls[0][1]).toBe('/api/notifications');
	});

	// Bate-volta (2ª passada): o badge roda em TODA navegação e pedia uma lista de 1 linha só
	// para descartá-la — 2 queries onde 1 basta. Agora tem rota própria.
	it('fetchUnreadCount usa a rota de contagem, sem pedir lista', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, badge));

		expect(await fetchUnreadCount(event)).toBe(badge.unread);
		expect(m.apiFetch.mock.calls[0][1]).toBe('/api/notifications/unread-count');
	});

	it('unread:true acrescenta ?unread=1', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, { notifications: [], unread: 0 }));
		await fetchNotifications(event, { unread: true });
		expect(m.apiFetch.mock.calls[0][1]).toBe('/api/notifications?unread=1');
	});

	// #54: limit/offset viraram query string; `offset: 0` não vai (é o default da API).
	it('limit e offset viram query string', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, { notifications: [], unread: 0 }));
		await fetchNotifications(event, { limit: 20, offset: 40 });
		expect(m.apiFetch.mock.calls[0][1]).toBe('/api/notifications?limit=20&offset=40');

		m.apiFetch.mockResolvedValueOnce(res(200, { notifications: [], unread: 0 }));
		await fetchNotifications(event, { limit: 20, offset: 0 });
		expect(m.apiFetch.mock.calls[1][1]).toBe('/api/notifications?limit=20');
	});

	it('não-2xx → data null com o status', async () => {
		m.apiFetch.mockResolvedValueOnce(res(401));
		expect(await fetchNotifications(event)).toEqual({ status: 401, data: null });
	});

	it('falha de rede → status 0, data null', async () => {
		m.apiFetch.mockRejectedValueOnce(new Error('down'));
		expect(await fetchNotifications(event)).toEqual({ status: 0, data: null });
	});
});

describe('fetchUnreadCount', () => {
	it('devolve o número de não-lidas', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, { notifications: [], unread: 4 }));
		expect(await fetchUnreadCount(event)).toBe(4);
	});

	it('erro → 0 (não derruba o shell)', async () => {
		m.apiFetch.mockResolvedValueOnce(res(500));
		expect(await fetchUnreadCount(event)).toBe(0);
	});
});

describe('marcar lida', () => {
	it('markNotificationRead posta em /:id/read', async () => {
		mut.mutate.mockResolvedValueOnce({ ok: true, status: 200 });
		await markNotificationRead(event, 'n1');
		expect(mut.mutate).toHaveBeenCalledWith(event, '/api/notifications/n1/read', 'POST');
	});

	it('markAllNotificationsRead posta em /read-all', async () => {
		mut.mutate.mockResolvedValueOnce({ ok: true, status: 200 });
		await markAllNotificationsRead(event);
		expect(mut.mutate).toHaveBeenCalledWith(event, '/api/notifications/read-all', 'POST');
	});
});

describe('limpar a caixa', () => {
	// DELETE na coleção (não um POST /clear-all): some a caixa inteira do dono. O verbo é o
	// contrato — trocá-lo por POST aqui esconderia que a operação é destrutiva.
	it('clearAllNotifications faz DELETE na coleção', async () => {
		mut.mutate.mockResolvedValueOnce({ ok: true, status: 200 });
		await clearAllNotifications(event);
		expect(mut.mutate).toHaveBeenCalledWith(event, '/api/notifications', 'DELETE');
	});
});

// O contrato com a API (doc 101, A2).
describe('contrato com a API', () => {
	it('a caixa traz a lista, o contador do badge e a página', () => {
		exigirCampos(caixa, ['notifications', 'unread', 'page'], 'notificacoes/caixa');
		exigirCampos(caixa.page, ['limit', 'offset', 'more'], 'notificacoes/caixa → page');
	});

	// `read` é DERIVADO de `read_at` do lado da API: a UI quer o estado, não o instante. Se algum
	// dia o serializer passar a mandar `read_at` cru, o sino deixaria de acender e nada acusaria.
	it('a notificação traz o estado já derivado, não o carimbo', () => {
		const n = primeiro(caixa.notifications, 'notificacoes/caixa → notifications');

		exigirCampos(n, ['id', 'kind', 'title', 'body', 'data', 'read', 'inserted_at'], 'caixa[0]');
		expect(typeof n.read).toBe('boolean');
	});

	it('o badge é só o número', () => {
		exigirCampos(badge, ['unread'], 'notificacoes/badge');
		expect(typeof badge.unread).toBe('number');
	});
});
