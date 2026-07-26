import { describe, it, expect, vi, beforeEach } from 'vitest';

const svc = vi.hoisted(() => ({
	fetchNotifications: vi.fn(),
	markNotificationRead: vi.fn(),
	markAllNotificationsRead: vi.fn()
}));
vi.mock('$lib/server/notifications', () => svc);

import { load, actions } from './+page.server';

// `url` entrou com a paginação (#54): o load lê `?page=` para virar `offset`.
const ev = (page?: string) =>
	({
		depends: vi.fn(),
		url: new URL(`http://x/notificacoes${page ? `?page=${page}` : ''}`)
	}) as never;

function formEvent(fields: Record<string, string>) {
	const form = new FormData();
	for (const [k, v] of Object.entries(fields)) form.set(k, v);
	return { request: { formData: async () => form } } as never;
}

beforeEach(() => Object.values(svc).forEach((fn) => fn.mockReset()));

const pagina = { limit: 20, offset: 0, more: false };

describe('load', () => {
	it('devolve as notificações e a contagem', async () => {
		svc.fetchNotifications.mockResolvedValueOnce({
			status: 200,
			data: { notifications: [{ id: 'n1' }], unread: 1, page: pagina }
		});

		expect(await load(ev())).toEqual({
			notifications: [{ id: 'n1' }],
			unread: 1,
			pageInfo: pagina,
			current: 1
		});
	});

	// #54: `?page=` da URL vira `offset` para a API — a mesma tradução da fila e de Pacientes.
	it('?page=3 vira offset', async () => {
		// Com uma linha: página 3 **vazia** hoje redireciona (ver o teste do beco abaixo), e o que
		// se afirma aqui é a tradução `?page=` → `offset`.
		svc.fetchNotifications.mockResolvedValueOnce({
			status: 200,
			data: {
				notifications: [{ id: 'n1' }],
				unread: 0,
				page: { limit: 20, offset: 40, more: false }
			}
		});

		const out = await load(ev('3'));

		expect(svc.fetchNotifications).toHaveBeenCalledWith(expect.anything(), {
			limit: 20,
			offset: 40
		});
		// `toMatchObject` e não `out.current`: o tipo do `load` inclui `void` (o `error()` do
		// caminho de falha), e o TS não estreita isso sozinho.
		expect(out).toMatchObject({ current: 3 });
	});

	// Bate-volta (2ª passada). Sondado no browser: `?page=5` numa caixa de 65 devolvia 0 linhas
	// **e nenhum botão** — o rodapé só renderiza quando há linhas. O usuário via "Nenhuma
	// notificação" tendo 65, sem caminho de volta a não ser editar a URL. Chega-se lá quando a
	// poda apaga linhas enquanto se pagina, ou por link velho.
	it('página além do fim volta para a primeira, em vez de virar beco', async () => {
		svc.fetchNotifications.mockResolvedValueOnce({
			status: 200,
			data: { notifications: [], unread: 0, page: { limit: 20, offset: 80, more: false } }
		});

		await expect(load(ev('5'))).rejects.toMatchObject({
			status: 303,
			location: '/notificacoes'
		});
	});

	// A caixa genuinamente vazia continua sendo estado vazio, não redirecionamento.
	it('caixa vazia na primeira página não redireciona', async () => {
		svc.fetchNotifications.mockResolvedValueOnce({
			status: 200,
			data: { notifications: [], unread: 0, page: { limit: 20, offset: 0, more: false } }
		});

		expect(await load(ev())).toMatchObject({ notifications: [], current: 1 });
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
		svc.markNotificationRead.mockResolvedValueOnce({
			ok: false,
			status: 404,
			error: 'Registro não encontrado.'
		});

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
