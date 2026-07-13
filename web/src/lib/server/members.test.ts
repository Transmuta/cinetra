import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiFetch = vi.fn();
vi.mock('./api', () => ({ apiFetch: (...args: unknown[]) => apiFetch(...args) }));

import { fetchMembers, inviteMember, updateMember, revokeMember, resendInvite } from './members';

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

const event = {} as never;

beforeEach(() => apiFetch.mockReset());

describe('fetchMembers', () => {
	it('200 → devolve data', async () => {
		apiFetch.mockResolvedValueOnce(json({ members: [], professionals: [] }));
		const r = await fetchMembers(event);
		expect(r.status).toBe(200);
		expect(r.data).toEqual({ members: [], professionals: [] });
	});

	it('403 → data null (o load decide o que mostrar)', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 403 }));
		const r = await fetchMembers(event);
		expect(r).toEqual({ status: 403, data: null });
	});
});

describe('inviteMember', () => {
	it('POST /api/members com corpo JSON', async () => {
		apiFetch.mockResolvedValueOnce(json({ member: {} }, 201));
		const r = await inviteMember(event, { email: 'x@y.com', papel: 'recepcao' });
		expect(r.ok).toBe(true);
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/members',
			expect.objectContaining({ method: 'POST' })
		);
	});

	it('422 → mensagem de dados inválidos', async () => {
		apiFetch.mockResolvedValueOnce(json({ error: 'invalid' }, 422));
		const r = await inviteMember(event, { email: 'x', papel: 'faxineiro' });
		expect(r.ok).toBe(false);
		expect(r.error).toMatch(/inválidos/i);
	});
});

describe('updateMember / revokeMember', () => {
	it('update 403 → mensagem de permissão', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 403 }));
		const r = await updateMember(event, 'id', { papel: 'admin' });
		expect(r.ok).toBe(false);
		expect(r.error).toMatch(/permissão/i);
	});

	it('revoke 204 → ok', async () => {
		apiFetch.mockResolvedValueOnce(new Response(null, { status: 204 }));
		expect((await revokeMember(event, 'id')).ok).toBe(true);
	});

	it('revoke 404 → não encontrado', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 404 }));
		expect((await revokeMember(event, 'id')).error).toMatch(/não encontrado/i);
	});

	it('exceção de rede → ok=false, status 0', async () => {
		apiFetch.mockRejectedValueOnce(new Error('ECONNREFUSED'));
		expect(await revokeMember(event, 'id')).toEqual({
			ok: false,
			status: 0,
			error: expect.any(String)
		});
	});
});

describe('resendInvite', () => {
	it('reenvia magic link para o e-mail', async () => {
		apiFetch.mockResolvedValueOnce(json({ ok: true }));
		const r = await resendInvite(event, 'x@y.com');
		expect(r.ok).toBe(true);
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/auth/magic-link',
			expect.objectContaining({ method: 'POST' })
		);
	});
});
