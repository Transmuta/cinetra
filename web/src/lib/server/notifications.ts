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
	opts: { unread?: boolean; limit?: number; offset?: number } = {}
): Promise<NotificationsResult> {
	try {
		const params = new URLSearchParams();
		if (opts.unread) params.set('unread', '1');
		if (opts.limit !== undefined) params.set('limit', String(opts.limit));
		if (opts.offset) params.set('offset', String(opts.offset));

		const qs = params.toString();
		const res = await apiFetch(event, `/api/notifications${qs ? `?${qs}` : ''}`, {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return { status: res.status, data: null };
		return {
			status: res.status,
			data: (await res.json()) as NotificationsData
		};
	} catch {
		return { status: 0, data: null };
	}
}

// O número do badge, para o layout. Falha silenciosa em 0 — um erro ao contar não deve derrubar
// o shell inteiro.
//
// Rota **própria**, e não `?unread=1&limit=1`, porque este é o endpoint mais chamado do sistema:
// roda no load do layout, em toda navegação. Pedindo pelo `index` ele custava duas queries —
// uma lista de uma linha, que esta função descartava, mais o `COUNT`. Sondado num carregamento
// real de `/pacientes` antes do conserto:
//
//     SELECT n0."read_at" FROM "notifications" ... (limit 1)   ← ninguém lê o resultado
//     SELECT coalesce(count(*), $1) FROM "notifications" ...   ← o número
export async function fetchUnreadCount(event: RequestEvent): Promise<number> {
	try {
		const res = await apiFetch(event, '/api/notifications/unread-count', {
			headers: { accept: 'application/json' }
		});
		if (!res.ok) return 0;
		const data = (await res.json()) as { unread?: number };
		return data.unread ?? 0;
	} catch {
		return 0;
	}
}

export function markNotificationRead(event: RequestEvent, id: string): Promise<MutationResult> {
	return mutate(event, `/api/notifications/${id}/read`, 'POST');
}

export function markAllNotificationsRead(event: RequestEvent): Promise<MutationResult> {
	return mutate(event, '/api/notifications/read-all', 'POST');
}
