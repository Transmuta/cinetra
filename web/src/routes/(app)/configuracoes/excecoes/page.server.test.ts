import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({
	fetchClinicExceptions: vi.fn(),
	createClinicException: vi.fn(),
	deleteClinicException: vi.fn()
}));
vi.mock('$lib/server/clinic-exceptions', () => m);

import { load, actions } from './+page.server';

type LoadOk = { exceptions: unknown[] };
const runLoad = async (): Promise<LoadOk> => (await load({} as never)) as LoadOk;

function ev(fields: Record<string, string>) {
	const fd = new FormData();
	for (const [k, v] of Object.entries(fields)) fd.set(k, v);
	return { request: { formData: async () => fd } } as never;
}

beforeEach(() => Object.values(m).forEach((fn) => fn.mockReset()));

describe('load', () => {
	it('200 → devolve as exceções', async () => {
		m.fetchClinicExceptions.mockResolvedValueOnce({
			status: 200,
			data: { clinic_exceptions: [{ id: 'e1' }] }
		});
		expect((await runLoad()).exceptions).toHaveLength(1);
	});

	it('sem data → error de gateway', async () => {
		m.fetchClinicExceptions.mockResolvedValueOnce({ status: 502, data: null });
		await expect(load({} as never)).rejects.toMatchObject({ status: 502 });
	});
});

describe('action add', () => {
	it('sem data → fail 400 sem tocar na API', async () => {
		const r = await actions.add(ev({ tipo: 'fechado' }));
		expect(r).toMatchObject({ status: 400 });
		expect(m.createClinicException).not.toHaveBeenCalled();
	});

	it('fechado → cria com periods vazio (ignora o campo periods)', async () => {
		m.createClinicException.mockResolvedValueOnce({ ok: true, status: 201 });
		const r = await actions.add(
			ev({ data: '2026-07-09', nome: 'Feriado', tipo: 'fechado', periods: '[["08:00","12:00"]]' })
		);
		expect(r).toEqual({ action: 'add', ok: true });
		expect(m.createClinicException).toHaveBeenCalledWith(
			expect.anything(),
			{ data: '2026-07-09', nome: 'Feriado', tipo: 'fechado', periods: [] },
			// Sem `confirm` no form, o gate do A3/D12 vale.
			false
		);
	});

	it('horario → cria com os períodos parseados', async () => {
		m.createClinicException.mockResolvedValueOnce({ ok: true, status: 201 });
		await actions.add(
			ev({ data: '2026-07-24', tipo: 'horario', periods: '[["08:00","12:00"]]' })
		);
		expect(m.createClinicException).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ tipo: 'horario', periods: [['08:00', '12:00']] }),
			false
		);
	});

	it('horario com periods malformado → lista vazia (API decidirá o 422)', async () => {
		m.createClinicException.mockResolvedValueOnce({ ok: false, status: 422, error: 'x' });
		await actions.add(ev({ data: '2026-07-24', tipo: 'horario', periods: '{ nope' }));
		expect(m.createClinicException).toHaveBeenCalledWith(
			expect.anything(),
			expect.objectContaining({ periods: [] }),
			false
		);
	});

	it('data duplicada (422, H3) → fail com o status', async () => {
		m.createClinicException.mockResolvedValueOnce({ ok: false, status: 422, error: 'dup' });
		const r = await actions.add(ev({ data: '2026-12-25', tipo: 'fechado' }));
		expect(r).toMatchObject({ status: 422 });
	});
});

describe('action delete', () => {
	it('sem id → fail 400', async () => {
		const r = await actions.delete(ev({}));
		expect(r).toMatchObject({ status: 400 });
		expect(m.deleteClinicException).not.toHaveBeenCalled();
	});

	it('ok', async () => {
		m.deleteClinicException.mockResolvedValueOnce({ ok: true, status: 204 });
		expect(await actions.delete(ev({ id: 'e1' }))).toEqual({ action: 'delete', ok: true });
		expect(m.deleteClinicException).toHaveBeenCalledWith(expect.anything(), 'e1');
	});

	it('falha → fail com o status', async () => {
		m.deleteClinicException.mockResolvedValueOnce({ ok: false, status: 403, error: 'no' });
		expect(await actions.delete(ev({ id: 'e1' }))).toMatchObject({ status: 403 });
	});
});
