import { error, fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import {
	fetchNotifications,
	markNotificationRead,
	markAllNotificationsRead
} from '$lib/server/notifications';

// A caixa de notificações (doc 31). Leitura para todo membro (a API recorta por destinatário);
// as duas escritas são "marcar lida" (uma e todas). `depends` deixa o tempo real do layout
// revalidar SÓ esta lista quando chega uma notificação.
export const load: PageServerLoad = async (event) => {
	event.depends('notificacoes:dados');

	const { data, status } = await fetchNotifications(event);
	if (!data) error(status || 502, 'Não foi possível carregar as notificações.');

	return { notifications: data.notifications, unread: data.unread };
};

export const actions: Actions = {
	// Marca uma como lida (a linha, ao ser aberta).
	read: async (event) => {
		const form = await event.request.formData();
		const id = String(form.get('id') ?? '');
		if (!id) return fail(400, { action: 'read', error: 'Notificação inválida.' });

		const res = await markNotificationRead(event, id);
		if (!res.ok) return fail(res.status || 400, { action: 'read', error: res.error });

		return { ok: true, action: 'read' };
	},

	// Zera o badge.
	readAll: async (event) => {
		const res = await markAllNotificationsRead(event);
		if (!res.ok) return fail(res.status || 400, { action: 'readAll', error: res.error });

		return { ok: true, action: 'readAll' };
	}
};
