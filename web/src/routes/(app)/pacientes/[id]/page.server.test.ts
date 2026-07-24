import { describe, it, expect, vi, beforeEach } from 'vitest';

const pf = vi.hoisted(() => ({ fetchProfessionals: vi.fn() }));
vi.mock('$lib/server/professionals', () => pf);

const at = vi.hoisted(() => ({ fetchAppointmentTypes: vi.fn() }));
vi.mock('$lib/server/appointment-types', () => at);

const m = vi.hoisted(() => ({
	fetchPatient: vi.fn(),
	deactivatePatient: vi.fn(),
	reactivatePatient: vi.fn()
}));
vi.mock('$lib/server/patients', () => m);

const k = vi.hoisted(() => ({
	fetchPatientPackages: vi.fn(),
	pausePackage: vi.fn(),
	resumePackage: vi.fn(),
	cancelPackage: vi.fn()
}));
vi.mock('$lib/server/packages', () => k);

import { load, actions } from './+page.server';

beforeEach(() => {
	[...Object.values(pf), ...Object.values(at), ...Object.values(m), ...Object.values(k)].forEach(
		(fn) => fn.mockReset()
	);
	k.fetchPatientPackages.mockResolvedValue({ status: 200, packages: [] });
	at.fetchAppointmentTypes.mockResolvedValue({
		status: 200,
		data: { appointment_types: [] }
	});
});

describe('load', () => {
	it('200 → paciente + diretório + tipos + pacotes', async () => {
		m.fetchPatient.mockResolvedValueOnce({
			status: 200,
			patient: { id: 'pac1', nome: 'Mari' }
		});
		pf.fetchProfessionals.mockResolvedValueOnce({
			data: { professionals: [{ id: 'p1' }] }
		});
		at.fetchAppointmentTypes.mockResolvedValueOnce({
			status: 200,
			data: { appointment_types: [{ id: 't1' }] }
		});
		k.fetchPatientPackages.mockResolvedValueOnce({
			status: 200,
			packages: [{ id: 'k1' }]
		});
		const r = (await load({ params: { id: 'pac1' } } as never)) as {
			patient: { nome: string };
			appointmentTypes: unknown[];
			packages: unknown[];
		};
		expect(r.patient.nome).toBe('Mari');
		expect(r.appointmentTypes).toEqual([{ id: 't1' }]);
		expect(r.packages).toEqual([{ id: 'k1' }]);
	});
	it('não encontrado → 404', async () => {
		m.fetchPatient.mockResolvedValueOnce({ status: 404, patient: null });
		pf.fetchProfessionals.mockResolvedValueOnce({ data: null });
		await expect(load({ params: { id: 'x' } } as never)).rejects.toMatchObject({
			status: 404
		});
	});
});

describe('actions arquivar/reativar', () => {
	const ev = { params: { id: 'pac1' } } as never;

	it('deactivate ok → { archived: true }', async () => {
		m.deactivatePatient.mockResolvedValueOnce({ ok: true });
		expect(await actions.deactivate(ev)).toEqual({ archived: true });
	});
	it('reactivate ok → { archived: false }', async () => {
		m.reactivatePatient.mockResolvedValueOnce({ ok: true });
		expect(await actions.reactivate(ev)).toEqual({ archived: false });
	});
	it('deactivate recusado (403) → fail', async () => {
		m.deactivatePatient.mockResolvedValueOnce({ ok: false, status: 403 });
		expect(await actions.deactivate(ev)).toMatchObject({ status: 403 });
	});
});

describe('actions do ciclo de vida do pacote', () => {
	// O `id` do pacote chega do form-data; monta um evento com esse corpo.
	const evWith = (id: unknown) =>
		({
			params: { id: 'pac1' },
			request: {
				formData: async () => new Map(id === undefined ? [] : [['package_id', id]])
			}
		}) as never;

	it('pausePackage ok → { ok: true }', async () => {
		k.pausePackage.mockResolvedValueOnce({ ok: true });
		expect(await actions.pausePackage(evWith('k1'))).toEqual({ ok: true });
		expect(k.pausePackage.mock.calls[0][1]).toBe('k1');
	});

	it('resumePackage ok → { ok: true }', async () => {
		k.resumePackage.mockResolvedValueOnce({ ok: true });
		expect(await actions.resumePackage(evWith('k1'))).toEqual({ ok: true });
	});

	it('cancelPackage recusado (403) → fail', async () => {
		k.cancelPackage.mockResolvedValueOnce({
			ok: false,
			status: 403,
			error: 'não pode'
		});
		expect(await actions.cancelPackage(evWith('k1'))).toMatchObject({
			status: 403
		});
	});

	it('sem package_id → 400', async () => {
		expect(await actions.pausePackage(evWith(undefined))).toMatchObject({
			status: 400
		});
		expect(k.pausePackage).not.toHaveBeenCalled();
	});
});
