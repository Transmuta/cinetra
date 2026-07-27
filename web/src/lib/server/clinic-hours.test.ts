import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiFetch = vi.fn();
vi.mock('./api', () => ({ apiFetch: (...args: unknown[]) => apiFetch(...args) }));

import { fetchClinicHours, updateClinicHours } from './clinic-hours';
import type { WeekHours } from '$lib/scheduling';

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'content-type': 'application/json' }
	});
}

const event = {} as never;
const week: WeekHours = { '1': [['08:00', '12:00']], '0': [] };

beforeEach(() => apiFetch.mockReset());

describe('fetchClinicHours', () => {
	it('200 → devolve o mapa da semana', async () => {
		apiFetch.mockResolvedValueOnce(json({ clinic_hours: week }));
		const r = await fetchClinicHours(event);
		expect(r.status).toBe(200);
		expect(r.data?.clinic_hours['1']).toEqual([['08:00', '12:00']]);
	});

	it('erro → data null', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 502 }));
		expect(await fetchClinicHours(event)).toEqual({ status: 502, data: null });
	});

	it('falha de rede não explode o load', async () => {
		apiFetch.mockRejectedValueOnce(new Error('ECONNREFUSED'));
		expect(await fetchClinicHours(event)).toEqual({ status: 0, data: null });
	});
});

describe('updateClinicHours', () => {
	it('PATCH /api/clinic-hours com o corpo { clinic_hours }', async () => {
		apiFetch.mockResolvedValueOnce(json({ clinic_hours: week }));
		const r = await updateClinicHours(event, week);
		expect(r.ok).toBe(true);
		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/clinic-hours',
			expect.objectContaining({
				method: 'PATCH',
				// `confirm` vai SEMPRE no corpo (A3/D12); `false` é o default seguro.
				body: JSON.stringify({ clinic_hours: week, confirm: false })
			})
		);
	});

	it('422 (períodos inválidos) → mensagem de dados inválidos', async () => {
		apiFetch.mockResolvedValueOnce(json({ error: 'invalid', details: [] }, 422));
		expect((await updateClinicHours(event, week)).error).toMatch(/inválidos/i);
	});

	it('403 (papel errado) → mensagem de permissão', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 403 }));
		expect((await updateClinicHours(event, week)).error).toMatch(/permissão/i);
	});
});
