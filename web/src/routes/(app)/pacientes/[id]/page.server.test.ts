import { describe, it, expect, vi, beforeEach } from 'vitest';

const pf = vi.hoisted(() => ({ fetchProfessionals: vi.fn() }));
vi.mock('$lib/server/professionals', () => pf);

const at = vi.hoisted(() => ({ fetchAppointmentTypes: vi.fn() }));
vi.mock('$lib/server/appointment-types', () => at);

const m = vi.hoisted(() => ({
	fetchPatient: vi.fn(),
	fetchPatientHistory: vi.fn(),
	deactivatePatient: vi.fn(),
	reactivatePatient: vi.fn()
}));
vi.mock('$lib/server/patients', () => m);

const k = vi.hoisted(() => ({
	fetchPatientPackages: vi.fn(),
	pausePackage: vi.fn(),
	resumePackage: vi.fn(),
	cancelPackage: vi.fn(),
	archivePackage: vi.fn(),
	addPackageSession: vi.fn(),
	removePackageSession: vi.fn(),
	adjustPackageGrade: vi.fn()
}));
vi.mock('$lib/server/packages', () => k);

import { load, actions } from './+page.server';

// O load lê `?historico=` da URL, então o evento falso precisa de uma.
const ev = (query = '', id = 'pac1') =>
	({
		params: { id },
		url: new URL(`http://localhost/pacientes/${id}${query}`)
	}) as never;

beforeEach(() => {
	[...Object.values(pf), ...Object.values(at), ...Object.values(m), ...Object.values(k)].forEach(
		(fn) => fn.mockReset()
	);
	k.fetchPatientPackages.mockResolvedValue({ status: 200, packages: [] });
	m.fetchPatientHistory.mockResolvedValue({ status: 200, sessions: [], more: false });
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
		const r = (await load(ev())) as {
			patient: { nome: string };
			appointmentTypes: unknown[];
			packages: unknown[];
		};
		expect(r.patient.nome).toBe('Mari');
		expect(r.appointmentTypes).toEqual([{ id: 't1' }]);
		expect(r.packages).toEqual([{ id: 'k1' }]);
	});
	it('o histórico entra no load (C13, Frente 7)', async () => {
		m.fetchPatient.mockResolvedValueOnce({ status: 200, patient: { id: 'pac1', nome: 'Mari' } });
		pf.fetchProfessionals.mockResolvedValueOnce({ data: { professionals: [] } });
		m.fetchPatientHistory.mockResolvedValueOnce({
			status: 200,
			sessions: [{ id: 'att1', status: 'faltou' }],
			more: true,
			upcoming: [],
			upcomingMore: false
		});

		const r = (await load(ev()) ) as {
			history: unknown[];
			historyMore: boolean;
		};

		expect(r.history).toHaveLength(1);
		expect(r.historyMore).toBe(true);
	});

	// doc 56 — as próximas são cartão próprio; antes vinham no topo do histórico com o selo
	// "Previsto", afirmando como passado o que ainda não aconteceu.
	it('as próximas entram no load, separadas do histórico', async () => {
		m.fetchPatient.mockResolvedValueOnce({ status: 200, patient: { id: 'pac1', nome: 'Mari' } });
		pf.fetchProfessionals.mockResolvedValueOnce({ data: { professionals: [] } });
		m.fetchPatientHistory.mockResolvedValueOnce({
			status: 200,
			sessions: [],
			more: false,
			upcoming: [{ id: 'att9' }],
			upcomingMore: true
		});

		const r = (await load(ev())) as { upcoming: unknown[]; upcomingMore: boolean };

		expect(r.upcoming).toHaveLength(1);
		expect(r.upcomingMore).toBe(true);
	});

	// A ficha abre com poucas linhas de histórico (doc 56: 50 linhas eram ~2.200px num cartão só).
	// "Ver histórico completo" é um link que sobe o teto pela URL — sem estado no cliente.
	it('pede 8 sessões por padrão', async () => {
		m.fetchPatient.mockResolvedValueOnce({ status: 200, patient: { id: 'pac1', nome: 'Mari' } });
		pf.fetchProfessionals.mockResolvedValueOnce({ data: { professionals: [] } });

		await load(ev());

		expect(m.fetchPatientHistory.mock.calls[0][2]).toBe(8);
	});

	it('?historico= sobe o teto, respeitando o máximo da API', async () => {
		m.fetchPatient.mockResolvedValue({ status: 200, patient: { id: 'pac1', nome: 'Mari' } });
		pf.fetchProfessionals.mockResolvedValue({ data: { professionals: [] } });

		await load(ev('?historico=200'));
		expect(m.fetchPatientHistory.mock.calls[0][2]).toBe(200);

		m.fetchPatientHistory.mockClear();
		await load(ev('?historico=9999'));
		expect(m.fetchPatientHistory.mock.calls[0][2]).toBe(200);

		m.fetchPatientHistory.mockClear();
		await load(ev('?historico=abacaxi'));
		expect(m.fetchPatientHistory.mock.calls[0][2]).toBe(8);
	});

	it('não encontrado → 404', async () => {
		m.fetchPatient.mockResolvedValueOnce({ status: 404, patient: null });
		pf.fetchProfessionals.mockResolvedValueOnce({ data: null });
		await expect(load(ev('', 'x'))).rejects.toMatchObject({
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


// O ciclo de vida reaberto (doc 69 §10 B4): arquivar, o `+`/`−` do ADR-011 e a grade.
describe('actions novas do pacote', () => {
	const evForm = (pares: [string, string][]) =>
		({
			params: { id: 'pac1' },
			request: { formData: async () => new Map(pares) }
		}) as never;

	it('archivePackage ok → { ok: true }', async () => {
		k.archivePackage.mockResolvedValueOnce({ ok: true });
		expect(await actions.archivePackage(evForm([['package_id', 'k1']]))).toEqual({ ok: true });
		expect(k.archivePackage.mock.calls[0][1]).toBe('k1');
	});

	it('archivePackage recusado (422, sessão futura de pé) sobe a mensagem do servidor', async () => {
		k.archivePackage.mockResolvedValueOnce({
			ok: false,
			status: 422,
			error: 'ainda há sessões futuras neste pacote'
		});
		expect(await actions.archivePackage(evForm([['package_id', 'k1']]))).toMatchObject({
			status: 422
		});
	});

	it('addPackageSession e removePackageSession passam só o id', async () => {
		k.addPackageSession.mockResolvedValueOnce({ ok: true });
		k.removePackageSession.mockResolvedValueOnce({ ok: true });

		await actions.addPackageSession(evForm([['package_id', 'k1']]));
		await actions.removePackageSession(evForm([['package_id', 'k1']]));

		expect(k.addPackageSession.mock.calls[0][1]).toBe('k1');
		expect(k.removePackageSession.mock.calls[0][1]).toBe('k1');
	});

	// O form manda a grade PLANA (`dows=1,3` e `horarios=1=08:00,3=09:00`) e é aqui que ela vira o
	// objeto que a API recebe. É a única lógica de verdade destas actions.
	it('adjustPackageGrade remonta a grade a partir do formato plano', async () => {
		k.adjustPackageGrade.mockResolvedValueOnce({ ok: true });

		const r = await actions.adjustPackageGrade(
			evForm([
				['package_id', 'k1'],
				['dows', '1,3'],
				['horarios', '1=08:00,3=09:00'],
				['professional_id', 'pr1']
			])
		);

		expect(r).toEqual({ ok: true });
		expect(k.adjustPackageGrade.mock.calls[0][2]).toEqual({
			dows: [1, 3],
			horarios: { '1': '08:00', '3': '09:00' },
			professional_id: 'pr1'
		});
	});

	it('dia fora de 0..6 é descartado em vez de ir para a API', async () => {
		k.adjustPackageGrade.mockResolvedValueOnce({ ok: true });

		await actions.adjustPackageGrade(
			evForm([
				['package_id', 'k1'],
				['dows', '1,9,x'],
				['horarios', '1=08:00'],
				['professional_id', 'pr1']
			])
		);

		expect(k.adjustPackageGrade.mock.calls[0][2].dows).toEqual([1]);
	});

	it('dia sem horário → 400 sem tocar a API', async () => {
		const r = await actions.adjustPackageGrade(
			evForm([
				['package_id', 'k1'],
				['dows', '1,3'],
				['horarios', '1=08:00'],
				['professional_id', 'pr1']
			])
		);

		expect(r).toMatchObject({ status: 400 });
		expect(k.adjustPackageGrade).not.toHaveBeenCalled();
	});

	it('sem profissional → 400', async () => {
		const r = await actions.adjustPackageGrade(
			evForm([
				['package_id', 'k1'],
				['dows', '1'],
				['horarios', '1=08:00']
			])
		);

		expect(r).toMatchObject({ status: 400 });
	});

	it('conflito no servidor (422) sobe com a mensagem', async () => {
		k.adjustPackageGrade.mockResolvedValueOnce({
			ok: false,
			status: 422,
			error: 'Choca com outro agendamento.'
		});

		const r = await actions.adjustPackageGrade(
			evForm([
				['package_id', 'k1'],
				['dows', '1'],
				['horarios', '1=08:00'],
				['professional_id', 'pr1']
			])
		);

		expect(r).toMatchObject({ status: 422, data: { error: 'Choca com outro agendamento.' } });
	});
});
