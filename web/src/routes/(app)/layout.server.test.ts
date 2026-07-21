import { describe, it, expect, vi, beforeEach } from 'vitest';

const loadMe = vi.fn();
vi.mock('$lib/server/auth', () => ({ loadMe: (...a: unknown[]) => loadMe(...a) }));

const fetchUnreadCount = vi.fn();
vi.mock('$lib/server/notifications', () => ({
	fetchUnreadCount: (...a: unknown[]) => fetchUnreadCount(...a)
}));

import { load } from './+layout.server';
import { meFixture } from '$lib/testing/fixtures';

// O load real chama `event.depends` (etiqueta de invalidação do badge) e `fetchUnreadCount`.
const run = () => load({ depends: vi.fn() } as never);

beforeEach(() => {
	loadMe.mockReset();
	fetchUnreadCount.mockReset().mockResolvedValue(0);
});

describe('guarda do shell (app)/+layout.server', () => {
	it('sem sessão → redirect 303 para /entrar', async () => {
		loadMe.mockResolvedValueOnce(null);
		await expect(run()).rejects.toMatchObject({ status: 303, location: '/entrar' });
	});

	it('com sessão mas sem clínica ativa → redirect 303 para /comecar', async () => {
		loadMe.mockResolvedValueOnce(meFixture({ active_clinic_id: null }));
		await expect(run()).rejects.toMatchObject({ status: 303, location: '/comecar' });
	});

	it('com sessão e clínica ativa → devolve me e a contagem do badge', async () => {
		const me = meFixture({ user: { id: 'u1', nome: 'Ana', email: 'ana@x' } });
		loadMe.mockResolvedValueOnce(me);
		fetchUnreadCount.mockResolvedValueOnce(5);
		expect(await run()).toEqual({ me, unread: 5 });
	});
});
