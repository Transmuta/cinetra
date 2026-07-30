import { describe, it, expect, vi, beforeEach } from 'vitest';

// Mockar `./api` alcança também o `./mutate` (que importa apiFetch do mesmo módulo).
const apiFetch = vi.fn();
vi.mock('./api', () => ({ apiFetch: (...args: unknown[]) => apiFetch(...args) }));

import {
	fetchAppointmentTypes,
	createAppointmentType,
	updateAppointmentType,
	archiveAppointmentType,
	restoreAppointmentType
} from './appointment-types';

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

const event = {} as never;

const input = {
	nome: 'Sessão',
	duracao_minutos: 50,
	cor: '#0FB5A6',
	icon: 'Activity',
	grupo: false,
	capacidade: null
};

beforeEach(() => apiFetch.mockReset());

describe('fetchAppointmentTypes', () => {
	it('200 → devolve data (ativos e arquivados juntos; a tela separa)', async () => {
		apiFetch.mockResolvedValueOnce(json({ appointment_types: [{ id: 't1' }] }));
		const r = await fetchAppointmentTypes(event);
		expect(r.status).toBe(200);
		expect(r.data?.appointment_types).toHaveLength(1);
	});

	it('erro → data null (o load decide o que mostrar)', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 502 }));
		expect(await fetchAppointmentTypes(event)).toEqual({ status: 502, data: null });
	});

	it('falha de rede não explode o load', async () => {
		apiFetch.mockRejectedValueOnce(new Error('ECONNREFUSED'));
		expect(await fetchAppointmentTypes(event)).toEqual({ status: 0, data: null });
	});
});

describe('createAppointmentType', () => {
	it('POST /api/appointment-types com o corpo JSON', async () => {
		apiFetch.mockResolvedValueOnce(json({ appointment_type: {} }, 201));
		const r = await createAppointmentType(event, input);
		expect(r.ok).toBe(true);
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/appointment-types',
			expect.objectContaining({ method: 'POST', body: JSON.stringify(input) })
		);
	});

	it('422 (nome duplicado, T7) → mensagem de dados inválidos', async () => {
		apiFetch.mockResolvedValueOnce(json({ error: 'invalid', details: [] }, 422));
		const r = await createAppointmentType(event, input);
		expect(r.ok).toBe(false);
		expect(r.error).toMatch(/inválidos/i);
	});

	it('403 (papel errado, T8) → mensagem de permissão', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 403 }));
		expect((await createAppointmentType(event, input)).error).toMatch(/permissão/i);
	});
});

describe('updateAppointmentType', () => {
	it('PATCH /api/appointment-types/:id', async () => {
		apiFetch.mockResolvedValueOnce(json({ appointment_type: {} }));
		expect((await updateAppointmentType(event, 't1', input)).ok).toBe(true);
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/appointment-types/t1',
			expect.objectContaining({ method: 'PATCH' })
		);
	});

	it('id sai escapado — nada de sair do caminho do recurso', async () => {
		apiFetch.mockResolvedValueOnce(json({ appointment_type: {} }));
		await updateAppointmentType(event, '../../auth/sign-out', input);
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/appointment-types/..%2F..%2Fauth%2Fsign-out',
			expect.anything()
		);
	});

	it('404 (fora do tenant) → não encontrado', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 404 }));
		expect((await updateAppointmentType(event, 't1', input)).error).toMatch(/não encontrado/i);
	});
});

describe('archiveAppointmentType / restoreAppointmentType', () => {
	// T10: é transição de estado, não destroy — POST /:id/<verbo>, não DELETE.
	it('POST /api/appointment-types/:id/archive, sem corpo', async () => {
		apiFetch.mockResolvedValueOnce(json({ appointment_type: {} }));
		expect((await archiveAppointmentType(event, 't1')).ok).toBe(true);
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/appointment-types/t1/archive',
			expect.objectContaining({ method: 'POST', body: undefined })
		);
	});

	it('POST /api/appointment-types/:id/restore', async () => {
		apiFetch.mockResolvedValueOnce(json({ appointment_type: {} }));
		expect((await restoreAppointmentType(event, 't1')).ok).toBe(true);
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/appointment-types/t1/restore',
			expect.objectContaining({ method: 'POST' })
		);
	});

	it('exceção de rede → ok=false, status 0', async () => {
		apiFetch.mockRejectedValueOnce(new Error('ECONNREFUSED'));
		expect(await archiveAppointmentType(event, 't1')).toEqual({
			ok: false,
			status: 0,
			error: expect.any(String)
		});
	});
});
