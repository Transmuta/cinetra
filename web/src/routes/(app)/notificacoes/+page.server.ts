import { error, fail, redirect } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import {
	fetchNotifications,
	markNotificationRead,
	markAllNotificationsRead,
	clearAllNotifications
} from '$lib/server/notifications';
import { PAGE_SIZE, notificationsHref, onlyUnreadFrom } from '$lib/notifications';
import { parsePage } from '$lib/pagination';

// A caixa de notificações (doc 31). Leitura para todo membro (a API recorta por destinatário);
// as escritas são "marcar lida" (uma e todas) e "limpar tudo". `depends` deixa o tempo real do
// layout revalidar SÓ esta lista quando chega uma notificação.
//
// #54: a caixa é paginada. `?page=` na URL vira `offset`, mesma tradução da fila e de Pacientes
// (`$lib/pagination`) — a diferença é que aqui não há rodapé "X–Y de Z", porque a API não conta
// o total de propósito (ver `$lib/pagination`).
export const load: PageServerLoad = async (event) => {
	event.depends('notificacoes:dados');

	const current = parsePage(event.url.searchParams.get('page'));

	// O filtro mora na URL, como todo estado de lista do projeto — F5, botão voltar e link colado
	// continuam no mesmo filtro. Quem o desenha é a SIDEBAR do shell; a chave da query string tem
	// dono único em `$lib/notifications` (os dois lados leem dali, senão um renomeia e o outro
	// para de filtrar calado). E o recorte é aplicado NO SERVIDOR (`?unread=1` da API): filtrar
	// escondendo linha no browser quebraria a paginação — a página de 20 chegaria com 20 e
	// exibiria 3.
	const onlyUnread = onlyUnreadFrom(event.url.searchParams);

	const { data, status } = await fetchNotifications(event, {
		unread: onlyUnread,
		limit: PAGE_SIZE,
		offset: (current - 1) * PAGE_SIZE
	});

	if (!data) error(status || 502, 'Não foi possível carregar as notificações.');

	// Página além do fim volta para a primeira. Sem isto ela é um **beco**: o rodapé só existe
	// quando há linhas, então a tela mostrava "Nenhuma notificação" — a quem tem 65 — sem
	// caminho de volta que não fosse editar a URL. Chega-se lá quando a poda apaga linhas
	// enquanto se pagina, por link velho — ou agora, ao limpar a caixa estando na página 3.
	// Mesmo espírito do `parsePage`, que já normaliza `?page=` inválido: página fora de faixa não
	// é erro do usuário, é "começa do começo". O **filtro sobrevive** ao resgate: perdê-lo
	// mandaria quem está em "Não lidas" para "Todas" sem ter pedido.
	if (current > 1 && data.notifications.length === 0) redirect(303, notificationsHref(onlyUnread));

	return {
		notifications: data.notifications,
		unread: data.unread,
		pageInfo: data.page,
		current,
		onlyUnread
	};
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
	},

	// Esvazia a caixa — lidas e não-lidas, sem lixeira. A tela confirma antes; aqui não há mais
	// freio nenhum.
	clearAll: async (event) => {
		const res = await clearAllNotifications(event);
		if (!res.ok) return fail(res.status || 400, { action: 'clearAll', error: res.error });

		return { ok: true, action: 'clearAll' };
	}
};
