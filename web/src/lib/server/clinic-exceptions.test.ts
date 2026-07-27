import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiFetch = vi.fn();
vi.mock('./api', () => ({ apiFetch: (...args: unknown[]) => apiFetch(...args) }));

import {
	fetchClinicExceptions,
	createClinicException,
	deleteClinicException,
	type ClinicExceptionInput
} from './clinic-exceptions';

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

const event = {} as never;

const input: ClinicExceptionInput = {
	data: '2026-07-09',
	nome: 'Feriado',
	tipo: 'fechado',
	periods: []
};

beforeEach(() => apiFetch.mockReset());

describe('fetchClinicExceptions', () => {
	it('200 → devolve a lista', async () => {
		apiFetch.mockResolvedValueOnce(json({ clinic_exceptions: [{ id: 'e1' }] }));
		const r = await fetchClinicExceptions(event);
		expect(r.data?.clinic_exceptions).toHaveLength(1);
	});

	it('erro → data null', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 502 }));
		expect(await fetchClinicExceptions(event)).toEqual({ status: 502, data: null });
	});

	it('falha de rede não explode o load', async () => {
		apiFetch.mockRejectedValueOnce(new Error('ECONNREFUSED'));
		expect(await fetchClinicExceptions(event)).toEqual({ status: 0, data: null });
	});
});

describe('createClinicException', () => {
	it('POST /api/clinic-exceptions com o corpo JSON', async () => {
		apiFetch.mockResolvedValueOnce(json({ clinic_exception: {} }, 201));
		const r = await createClinicException(event, input);
		expect(r.ok).toBe(true);
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/clinic-exceptions',
			expect.objectContaining({
				method: 'POST',
				// `confirm` vai SEMPRE no corpo (A3/D12); `false` é o default seguro.
				body: JSON.stringify({ ...input, confirm: false })
			})
		);
	});

	it('422 (data duplicada, H3) → dados inválidos', async () => {
		apiFetch.mockResolvedValueOnce(json({ error: 'invalid', details: [] }, 422));
		expect((await createClinicException(event, input)).error).toMatch(/inválidos/i);
	});
});

describe('deleteClinicException', () => {
	it('DELETE /api/clinic-exceptions/:id', async () => {
		apiFetch.mockResolvedValueOnce(new Response(null, { status: 204 }));
		const r = await deleteClinicException(event, 'e1');
		expect(r.ok).toBe(true);
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/clinic-exceptions/e1',
			expect.objectContaining({ method: 'DELETE' })
		);
	});

	it('id sai escapado', async () => {
		apiFetch.mockResolvedValueOnce(new Response(null, { status: 204 }));
		await deleteClinicException(event, '../../auth/sign-out');
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/clinic-exceptions/..%2F..%2Fauth%2Fsign-out',
			expect.anything()
		);
	});

	it('404 → não encontrado', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 404 }));
		expect((await deleteClinicException(event, 'e1')).error).toMatch(/não encontrado/i);
	});
});
