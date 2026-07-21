import type { RequestEvent } from '@sveltejs/kit';
import { apiFetch } from './api';
import { mutate, type MutationResult } from './mutate';
import type { NotificationsData } from '$lib/notifications';

// BFF da caixa de notificações (doc 31 / ADR-005): fala com `/api/notifications`
// server-to-server, repassando o cookie de sessão. Leitura para todo membro (a API recorta por
// destinatário); a única escrita é "marcar lida". `clinic_id`, RBAC e recorte vivem na API.

export interface NotificationsResult {
	status: number;
	data: NotificationsData | null;
}

export async function fetchNotifications(
	event: RequestEvent,
	opts: { unread?: boolean } = {}
): Promise<NotificationsResult> {
	try {
		const suffix = opts.unread ? '?unread=1' : '';
		const res = await apiFetch(event, `/api/notifications${suffix}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return { status: res.status, data: (await res.json()) as NotificationsData };
	} catch {
		return { status: 0, data: null };
	}
}

// O número do badge, para o layout (barato: só as não-lidas + a contagem). Falha silenciosa em
// 0 — um erro ao contar não deve derrubar o shell inteiro.
export async function fetchUnreadCount(event: RequestEvent): Promise<number> {
	const { data } = await fetchNotifications(event, { unread: true });
	return data?.unread ?? 0;
}

export function markNotificationRead(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `/api/notifications/${id}/read`, 'POST');
}

export function markAllNotificationsRead(event: RequestEvent): Promise<MutationResult> {
	return mutate(event, '/api/notifications/read-all', 'POST');
}
