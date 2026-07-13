import { describe, it, expect, vi, beforeEach } from 'vitest';

const loadMe = vi.fn();
vi.mock('$lib/server/auth', () => ({ loadMe: (...a: unknown[]) => loadMe(...a) }));

import { load } from './+layout.server';

const run = () => load({} as never);

beforeEach(() => loadMe.mockReset());

describe('guarda do shell (app)/+layout.server', () => {
	it('sem sessão → redirect 303 para /entrar', async () => {
		loadMe.mockResolvedValueOnce(null);
		await expect(run()).rejects.toMatchObject({ status: 303, location: '/entrar' });
	});

	it('com sessão mas sem clínica ativa → redirect 303 para /comecar', async () => {
		loadMe.mockResolvedValueOnce({ active_clinic_id: null });
		await expect(run()).rejects.toMatchObject({ status: 303, location: '/comecar' });
	});

	it('com sessão e clínica ativa → devolve me', async () => {
		const me = { active_clinic_id: 'c1', user: { nome: 'Ana' } };
		loadMe.mockResolvedValueOnce(me);
		expect(await run()).toEqual({ me });
	});
});
