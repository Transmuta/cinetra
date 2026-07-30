import { describe, it, expect, vi, beforeEach } from 'vitest';

// vi.hoisted: o factory de vi.mock é içado para o topo; sem isso, `m` estaria na TDZ.
const m = vi.hoisted(() => ({
	fetchMembers: vi.fn(),
	inviteMember: vi.fn(),
	updateMember: vi.fn(),
	revokeMember: vi.fn(),
	resendInvite: vi.fn()
}));
vi.mock('$lib/server/members', () => m);

// AN-06: a matriz vem junto do load; a falha degrada para null (seção some, equipe continua).
const mx = vi.hoisted(() => ({ fetchAccessMatrix: vi.fn() }));
vi.mock('$lib/server/access-matrix', () => mx);

import { load, actions } from './+page.server';

// PageServerLoad inclui `void` no retorno (por causa de error/redirect que retornam never);
// nos casos de sucesso sabemos a forma concreta. Espelha o runLoad de routes/page.server.test.ts.
type LoadOk = { members: unknown[]; professionals: unknown[] };
const runLoad = async (): Promise<LoadOk> => (await load({} as never)) as LoadOk;

function ev(fields: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

beforeEach(() => {
	Object.values(m).forEach((fn) => fn.mockReset());
	mx.fetchAccessMatrix.mockReset();
	mx.fetchAccessMatrix.mockResolvedValue({ status: 0, data: null });
});

describe('load', () => {
	it('entrega a matriz de acesso quando a API responde (AN-06)', async () => {
		m.fetchMembers.mockResolvedValueOnce({ status: 200, data: { members: [], professionals: [] } });
		const matrix = { papeis: ['owner'], areas: [] };
		mx.fetchAccessMatrix.mockResolvedValueOnce({ status: 200, data: matrix });

		const r = (await load({} as never)) as { accessMatrix: unknown };
		expect(r.accessMatrix).toEqual(matrix);
	});

	it('matriz fora do ar degrada para null — a equipe continua', async () => {
		m.fetchMembers.mockResolvedValueOnce({ status: 200, data: { members: [], professionals: [] } });

		const r = (await load({} as never)) as { accessMatrix: unknown };
		expect(r.accessMatrix).toBeNull();
	});

	it('200 → members + professionals', async () => {
		m.fetchMembers.mockResolvedValueOnce({
			status: 200,
			data: { members: [{ id: 'x' }], professionals: [{ id: 'p' }] }
		});
		const r = await runLoad();
		expect(r.members).toHaveLength(1);
		expect(r.professionals).toHaveLength(1);
	});

	it('403 → error 403', async () => {
		m.fetchMembers.mockResolvedValueOnce({ status: 403, data: null });
		await expect(load({} as never)).rejects.toMatchObject({ status: 403 });
	});

	it('sem data → error de gateway', async () => {
		m.fetchMembers.mockResolvedValueOnce({ status: 502, data: null });
		await expect(load({} as never)).rejects.toMatchObject({ status: 502 });
	});
});

describe('action invite', () => {
	it('sem e-mail → fail 400', async () => {
		const r = await actions.invite(ev({ papel: 'recepcao' }));
		expect(r).toMatchObject({ status: 400 });
	});

	it('profissional sem vínculo → fail 400', async () => {
		const r = await actions.invite(ev({ email: 'x@y.com', papel: 'profissional' }));
		expect(r).toMatchObject({ status: 400 });
		expect(m.inviteMember).not.toHaveBeenCalled();
	});

	it('ok → { action: invite, ok: true }', async () => {
		m.inviteMember.mockResolvedValueOnce({ ok: true, status: 201 });
		const r = await actions.invite(ev({ email: 'x@y.com', nome: 'N', papel: 'recepcao' }));
		expect(r).toEqual({ action: 'invite', ok: true });
	});

	it('API falha → fail com erro', async () => {
		m.inviteMember.mockResolvedValueOnce({ ok: false, status: 422, error: 'ruim' });
		const r = await actions.invite(ev({ email: 'x@y.com', papel: 'recepcao' }));
		expect(r).toMatchObject({ status: 422 });
	});
});

describe('actions update / revoke / resend', () => {
	it('update sem id → fail 400', async () => {
		const r = await actions.update(ev({ papel: 'admin' }));
		expect(r).toMatchObject({ status: 400 });
	});

	it('update ok', async () => {
		m.updateMember.mockResolvedValueOnce({ ok: true, status: 200 });
		const r = await actions.update(ev({ id: 'm1', papel: 'admin' }));
		expect(r).toEqual({ action: 'update', ok: true });
	});

	it('revoke ok', async () => {
		m.revokeMember.mockResolvedValueOnce({ ok: true, status: 204 });
		const r = await actions.revoke(ev({ id: 'm1' }));
		expect(r).toEqual({ action: 'revoke', ok: true });
	});

	it('resend sem e-mail → fail 400', async () => {
		const r = await actions.resend(ev({}));
		expect(r).toMatchObject({ status: 400 });
	});

	it('resend ok', async () => {
		m.resendInvite.mockResolvedValueOnce({ ok: true, status: 200 });
		const r = await actions.resend(ev({ email: 'x@y.com' }));
		expect(r).toEqual({ action: 'resend', ok: true });
	});
});
