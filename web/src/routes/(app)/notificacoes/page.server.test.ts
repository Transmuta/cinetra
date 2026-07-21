import { describe, it, expect, vi, beforeEach } from 'vitest';

const svc = vi.hoisted(() => ({
	fetchNotifications: vi.fn(),
	markNotificationRead: vi.fn(),
	markAllNotificationsRead: vi.fn()
}));
vi.mock('$lib/server/notifications', () => svc);

import { load, actions } from './+page.server';

const ev = () => ({ depends: vi.fn() }) as never;

function formEvent(fields: Record<string, string>) {
	const form = new FormData();
	for (const [k, v] of Object.entries(fields)) form.set(k, v);
	return { request: { formData: async () => form } } as never;
}

beforeEach(() => Object.values(svc).forEach((fn) => fn.mockReset()));

describe('load', () => {
	it('devolve as notificações e a contagem', async () => {
		svc.fetchNotifications.mockResolvedValueOnce({
			status: 200,
			data: { notifications: [{ id: 'n1' }], unread: 1 }
		});

		expect(await load(ev())).toEqual({ notifications: [{ id: 'n1' }], unread: 1 });
	});

	it('sem dados → erro', async () => {
		svc.fetchNotifications.mockResolvedValueOnce({ status: 502, data: null });
		await expect(load(ev())).rejects.toMatchObject({ status: 502 });
	});
});

describe('action read', () => {
	it('marca a notificação e devolve ok', async () => {
		svc.markNotificationRead.mockResolvedValueOnce({ ok: true, status: 200 });

		const out = await actions.read(formEvent({ id: 'n1' }));
		expect(out).toEqual({ ok: true, action: 'read' });
		expect(svc.markNotificationRead).toHaveBeenCalledWith(expect.anything(), 'n1');
	});

	it('sem id → fail 400', async () => {
		const out = await actions.read(formEvent({}));
		expect(out).toMatchObject({ status: 400, data: { action: 'read' } });
		expect(svc.markNotificationRead).not.toHaveBeenCalled();
	});

	it('erro da API → fail com a mensagem', async () => {
		svc.markNotificationRead.mockResolvedValueOnce({ ok: false, status: 404, error: 'Registro não encontrado.' });

		const out = await actions.read(formEvent({ id: 'x' }));
		expect(out).toMatchObject({ status: 404, data: { error: 'Registro não encontrado.' } });
	});
});

describe('action readAll', () => {
	it('zera o badge', async () => {
		svc.markAllNotificationsRead.mockResolvedValueOnce({ ok: true, status: 200 });
		expect(await actions.readAll(ev())).toEqual({ ok: true, action: 'readAll' });
	});

	it('erro → fail', async () => {
		svc.markAllNotificationsRead.mockResolvedValueOnce({ ok: false, status: 500, error: 'x' });
		expect(await actions.readAll(ev())).toMatchObject({ status: 500 });
	});
});
