import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ updateProfile: vi.fn() }));
vi.mock('$lib/server/profile', () => m);

import { actions } from './+page.server';

function ev(fields: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

beforeEach(() => m.updateProfile.mockReset());

describe('action update', () => {
	it('nome preenchido → chama updateProfile com o nome aparado e devolve ok', async () => {
		m.updateProfile.mockResolvedValueOnce({ ok: true, status: 200 });

		const r = await actions.update(ev({ nome: '  Bianca Ferreira  ' }));

		expect(r).toEqual({ ok: true });
		expect(m.updateProfile).toHaveBeenCalledWith(expect.anything(), 'Bianca Ferreira');
	});

	it('nome vazio → fail 400 sem tocar na API', async () => {
		const r = await actions.update(ev({ nome: '   ' }));
		expect(r).toMatchObject({ status: 400 });
		expect(m.updateProfile).not.toHaveBeenCalled();
	});

	it('API recusa (422) → fail com o status e a mensagem', async () => {
		m.updateProfile.mockResolvedValueOnce({ ok: false, status: 422, error: 'ruim' });
		const r = await actions.update(ev({ nome: 'X' }));
		expect(r).toMatchObject({ status: 422, data: { error: 'ruim' } });
	});
});
