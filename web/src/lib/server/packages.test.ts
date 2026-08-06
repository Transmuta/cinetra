import { describe, it, expect, vi, beforeEach } from 'vitest';
import { contrato, exigirCampos, primeiro } from '$lib/testing/contrato';
import type { Package, PackageSession, PreviewResult } from '$lib/packages';

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
	archivePackage,
	addPackageSession,
	removePackageSession,
	adjustPackageGrade,
	fetchPackageSessions,
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

// Os corpos vêm de `contratos/bff/pacotes.json`, gravado pela API de verdade (doc 101, A2) — não
// mais escritos aqui. O mock inventado validava o BFF contra o BFF.
const lista = contrato<{ packages: Package[] }>('pacotes', 'lista_do_paciente');
const trilha = contrato<{ sessions: PackageSession[] }>('pacotes', 'trilha');
const previa = contrato<PreviewResult>('pacotes', 'previa');

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
		api.apiFetch.mockResolvedValueOnce(res(200, lista));
		const out = await fetchPatientPackages(event, 'p1');
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/patients/p1/packages');
		expect(out.packages).toEqual(lista.packages);
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
		api.apiFetch.mockResolvedValueOnce(res(200, previa));
		const out = await previewSeries(event, input);
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/packages/preview');
		expect(JSON.parse(api.apiFetch.mock.calls[0][2].body).total).toBe(4);
		expect(out.preview).toEqual(previa);
	});

	it('erro de forma → preview null', async () => {
		api.apiFetch.mockResolvedValueOnce(res(400, { error: 'bad_request' }));
		expect((await previewSeries(event, input)).preview).toBeNull();
	});
});

describe('createSeries', () => {
	it('201 → devolve o pacote criado', async () => {
		const criado = primeiro(lista.packages, 'pacotes/lista_do_paciente');
		api.apiFetch.mockResolvedValueOnce(res(201, { package: criado }));
		const out = await createSeries(event, input);
		expect(out.ok).toBe(true);
		expect(out.package?.id).toBe(criado.id);
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

// O ciclo de vida reaberto (doc 69 §10 B4).
describe('arquivar, +/− e grade', () => {
	it('arquivar bate no /archive', async () => {
		await archivePackage(event, 'k1');
		expect(mut.mutate.mock.calls[0][1]).toBe('/api/packages/k1/archive');
		expect(mut.mutate.mock.calls[0][2]).toBe('POST');
	});

	it('somar sessão é POST em /sessions', async () => {
		await addPackageSession(event, 'k1');
		expect(mut.mutate.mock.calls[0][1]).toBe('/api/packages/k1/sessions');
		expect(mut.mutate.mock.calls[0][2]).toBe('POST');
	});

	// Sem id de sessão no caminho: quem escolhe é o servidor (a última FUTURA, D3). Se o cliente
	// pudesse apontar, poderia apagar uma sessão passada — reescrita de histórico.
	it('tirar sessão é DELETE na coleção, sem apontar qual', async () => {
		await removePackageSession(event, 'k1');
		expect(mut.mutate.mock.calls[0][1]).toBe('/api/packages/k1/sessions');
		expect(mut.mutate.mock.calls[0][2]).toBe('DELETE');
	});

	it('a grade vai como PATCH com o corpo montado', async () => {
		await adjustPackageGrade(event, 'k1', {
			dows: [1, 3],
			horarios: { '1': '08:00', '3': '09:00' },
			professional_id: 'pr1'
		});
		expect(mut.mutate.mock.calls[0][1]).toBe('/api/packages/k1/grade');
		expect(mut.mutate.mock.calls[0][2]).toBe('PATCH');
		expect(mut.mutate.mock.calls[0][3]).toEqual({
			dows: [1, 3],
			horarios: { '1': '08:00', '3': '09:00' },
			professional_id: 'pr1'
		});
	});

	it('o id viaja escapado (id forjado não sai do caminho do recurso)', async () => {
		await addPackageSession(event, '../secret');
		expect(mut.mutate.mock.calls[0][1]).toBe('/api/packages/..%2Fsecret/sessions');
	});
});

describe('fetchPackageSessions', () => {
	it('200 → a trilha', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, trilha));
		const r = await fetchPackageSessions(event, 'k1');
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/packages/k1/sessions');
		expect(r.sessions).toEqual(trilha.sessions);
	});

	it('erro degrada para lista vazia, com o status', async () => {
		api.apiFetch.mockResolvedValueOnce(res(403));
		const r = await fetchPackageSessions(event, 'k1');
		expect(r).toEqual({ status: 403, sessions: [] });
	});

	it('corpo sem `sessions` não estoura', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, {}));
		expect((await fetchPackageSessions(event, 'k1')).sessions).toEqual([]);
	});

	it('falha de conexão → status 0 e lista vazia', async () => {
		api.apiFetch.mockRejectedValueOnce(new Error('down'));
		expect(await fetchPackageSessions(event, 'k1')).toEqual({ status: 0, sessions: [] });
	});
});

// O contrato com a API (doc 101, A2). Os campos abaixo são os que `$lib/packages` declara e o
// cartão da ficha desenha; a fixture é o que a API respondeu de verdade. Campo que sumir do
// serializer some daqui na regravação e o teste fica vermelho — hoje ele chegaria `undefined` na
// tela, calado.
describe('contrato com a API', () => {
	it('o pacote traz os campos que a ficha lê', () => {
		exigirCampos(
			primeiro(lista.packages, 'pacotes/lista_do_paciente'),
			[
				'id',
				'nome',
				'status',
				'total',
				'usadas',
				'restantes',
				'acabando',
				'falta_punitiva',
				'cor',
				'data_inicio',
				'appointment_type_id',
				'grade',
				'sessoes'
			],
			'pacotes/lista_do_paciente → packages[0]'
		);
	});

	it('a grade traz o que o modal de ajuste manda de volta', () => {
		const pacote = primeiro(lista.packages, 'pacotes/lista_do_paciente');
		exigirCampos(pacote.grade, ['dows', 'horarios', 'professional_id'], 'packages[0].grade');
	});

	// A trilha é a mesma forma nas duas portas (vem junto da listagem e sozinha em `/sessions`) —
	// é por isso que `PackageSession` é um tipo só, reexportado (doc 94 §4.5).
	it('a sessão da trilha traz o que a bolinha e o link ao bloco precisam', () => {
		for (const [nome, sessoes] of [
			['pacotes/lista_do_paciente → packages[0].sessoes', primeiro(lista.packages, 'x').sessoes],
			['pacotes/trilha → sessions', trilha.sessions]
		] as const) {
			exigirCampos(
				primeiro(sessoes ?? [], nome),
				['attendance_id', 'appointment_id', 'starts_at', 'estado'],
				nome
			);
		}
	});

	it('a prévia traz o que o save-gate decide', () => {
		exigirCampos(previa, ['ocorrencias', 'bloqueios', 'pode_salvar'], 'pacotes/previa');
		exigirCampos(
			primeiro(previa.ocorrencias, 'pacotes/previa → ocorrencias'),
			['data', 'hhmm', 'feriado', 'issue', 'bloqueia'],
			'pacotes/previa → ocorrencias[0]'
		);
	});
});
