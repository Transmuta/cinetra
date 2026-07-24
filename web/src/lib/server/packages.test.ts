import { describe, it, expect, vi, beforeEach } from 'vitest';

const api = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => api);
const mut = vi.hoisted(() => ({ mutate: vi.fn() }));
vi.mock('./mutate', () => mut);

import {
	fetchPatientPackages,
	previewSeries,
	createSeries,
	pausePackage,
	resumePackage,
	cancelPackage,
	type SeriesInput
} from './packages';

function res(status: number, body?: unknown): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		json: async () => {
			if (body === undefined) throw new SyntaxError('não é JSON');
			return body;
		}
	} as unknown as Response;
}

const event = {} as never;

beforeEach(() => {
	api.apiFetch.mockReset();
	mut.mutate.mockReset();
	mut.mutate.mockResolvedValue({ ok: true, status: 200 });
});

const input: SeriesInput = {
	nome: 'Pilates 4',
	total: 4,
	falta_punitiva: true,
	cor: '#0FB5A6',
	data_inicio: '2026-07-20',
	patient_id: 'p1',
	appointment_type_id: 't1',
	grade: { dows: [1, 3], horarios: { '1': '08:00', '3': '09:00' }, professional_id: 'pr1' }
};

describe('fetchPatientPackages', () => {
	it('200 → os pacotes do paciente', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { packages: [{ id: 'k1' }] }));
		const out = await fetchPatientPackages(event, 'p1');
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/patients/p1/packages');
		expect(out.packages).toEqual([{ id: 'k1' }]);
	});

	it('id é escapado no caminho', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { packages: [] }));
		await fetchPatientPackages(event, '../secret');
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/patients/..%2Fsecret/packages');
	});

	it('erro → lista vazia, sem estourar', async () => {
		api.apiFetch.mockResolvedValueOnce(res(500));
		const out = await fetchPatientPackages(event, 'p1');
		expect(out).toEqual({ status: 500, packages: [] });
	});

	it('falha de conexão → status 0', async () => {
		api.apiFetch.mockRejectedValueOnce(new Error('down'));
		expect(await fetchPatientPackages(event, 'p1')).toEqual({ status: 0, packages: [] });
	});
});

describe('previewSeries', () => {
	it('POSTa a série e devolve a prévia', async () => {
		const preview = { ocorrencias: [], bloqueios: 0, pode_salvar: true };
		api.apiFetch.mockResolvedValueOnce(res(200, preview));
		const out = await previewSeries(event, input);
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/packages/preview');
		expect(JSON.parse(api.apiFetch.mock.calls[0][2].body).total).toBe(4);
		expect(out.preview).toEqual(preview);
	});

	it('erro de forma → preview null', async () => {
		api.apiFetch.mockResolvedValueOnce(res(400, { error: 'bad_request' }));
		expect((await previewSeries(event, input)).preview).toBeNull();
	});
});

describe('createSeries', () => {
	it('201 → devolve o pacote criado', async () => {
		api.apiFetch.mockResolvedValueOnce(res(201, { package: { id: 'k1', status: 'ativo' } }));
		const out = await createSeries(event, input);
		expect(out.ok).toBe(true);
		expect(out.package?.id).toBe('k1');
	});

	it('422 series_blocked → devolve motivo + prévia para reapresentar', async () => {
		const preview = { ocorrencias: [], bloqueios: 1, pode_salvar: false };
		api.apiFetch.mockResolvedValueOnce(
			res(422, { error: 'series_blocked', reason: 'precisa_confirmar', preview })
		);
		const out = await createSeries(event, input);
		expect(out.ok).toBe(false);
		expect(out.blocked).toEqual({ reason: 'precisa_confirmar', preview });
	});

	it('422 fora_expediente também vem estruturado', async () => {
		const preview = { ocorrencias: [], bloqueios: 2, pode_salvar: false };
		api.apiFetch.mockResolvedValueOnce(
			res(422, { error: 'series_blocked', reason: 'fora_expediente', preview })
		);
		expect((await createSeries(event, input)).blocked?.reason).toBe('fora_expediente');
	});

	it('outro erro → mensagem genérica', async () => {
		api.apiFetch.mockResolvedValueOnce(res(500));
		const out = await createSeries(event, input);
		expect(out.ok).toBe(false);
		expect(out.error).toBeTruthy();
	});

	it('falha de conexão → status 0', async () => {
		api.apiFetch.mockRejectedValueOnce(new Error('down'));
		expect((await createSeries(event, input)).status).toBe(0);
	});
});

describe('ciclo de vida (reusa mutate)', () => {
	it('pausar bate no /pause do id escapado', async () => {
		await pausePackage(event, 'k 1');
		expect(mut.mutate.mock.calls[0][1]).toBe('/api/packages/k%201/pause');
		expect(mut.mutate.mock.calls[0][2]).toBe('POST');
	});

	it('retomar bate no /resume', async () => {
		await resumePackage(event, 'k1');
		expect(mut.mutate.mock.calls[0][1]).toBe('/api/packages/k1/resume');
	});

	it('cancelar bate no /cancel', async () => {
		await cancelPackage(event, 'k1');
		expect(mut.mutate.mock.calls[0][1]).toBe('/api/packages/k1/cancel');
	});
});
