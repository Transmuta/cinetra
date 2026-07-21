import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => m);

const mut = vi.hoisted(() => ({ mutate: vi.fn() }));
vi.mock('./mutate', () => mut);

import {
	fetchNotifications,
	fetchUnreadCount,
	markNotificationRead,
	markAllNotificationsRead
} from './notifications';

const event = {} as never;

function res(status: number, body?: unknown) {
	return { ok: status >= 200 && status < 300, status, json: async () => body };
}

beforeEach(() => {
	m.apiFetch.mockReset();
	mut.mutate.mockReset();
});

describe('fetchNotifications', () => {
	it('200 → devolve os dados', async () => {
		const data = { notifications: [{ id: 'n1' }], unread: 1 };
		m.apiFetch.mockResolvedValueOnce(res(200, data));

		const out = await fetchNotifications(event);
		expect(out).toEqual({ status: 200, data });
		expect(m.apiFetch.mock.calls[0][1]).toBe('/api/notifications');
	});

	it('unread:true acrescenta ?unread=1', async () => {
		m.apiFetch.mockResolvedValueOnce(res(200, { notifications: [], unread: 0 }));
		await fetchNotifications(event, { unread: true });
		expect(m.apiFetch.mock.calls[0][1]).toBe('/api/notifications?unread=1');
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
