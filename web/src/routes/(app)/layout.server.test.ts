import { describe, it, expect, vi, beforeEach } from 'vitest';

const loadMe = vi.fn();
vi.mock('$lib/server/auth', () => ({ loadMe: (...a: unknown[]) => loadMe(...a) }));

import { load } from './+layout.server';
import { meFixture } from '$lib/testing/fixtures';

const run = () => load({} as never);

beforeEach(() => loadMe.mockReset());

describe('guarda do shell (app)/+layout.server', () => {
	it('sem sessão → redirect 303 para /entrar', async () => {
		loadMe.mockResolvedValueOnce(null);
		await expect(run()).rejects.toMatchObject({ status: 303, location: '/entrar' });
	});

	it('com sessão mas sem clínica ativa → redirect 303 para /comecar', async () => {
		loadMe.mockResolvedValueOnce(meFixture({ active_clinic_id: null }));
		await expect(run()).rejects.toMatchObject({ status: 303, location: '/comecar' });
	});

	it('com sessão e clínica ativa → devolve me', async () => {
		const me = meFixture({ user: { id: 'u1', nome: 'Ana', email: 'ana@x' } });
		loadMe.mockResolvedValueOnce(me);
		expect(await run()).toEqual({ me });
	});
});
