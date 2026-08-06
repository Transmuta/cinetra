import { describe, it, expect, vi, beforeEach } from 'vitest';
import { contrato, exigirCampos, primeiro } from '$lib/testing/contrato';
import type { WaitlistData } from './waitlist';

const api = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => api);
const mut = vi.hoisted(() => ({ mutate: vi.fn() }));
vi.mock('./mutate', () => mut);

import {
	fetchWaitlist,
	fetchSlots,
	fetchAllSlots,
	fetchCandidates,
	enqueueEntry,
	updateEntry,
	dequeueEntry,
	convertEntry
} from './waitlist';

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
	mut.mutate.mockResolvedValue({ ok: true, status: 201 });
});

// A janela é obrigatória desde o F6 — a fila é paginada, e as duas chamadas da tela pedem a
// MESMA (fila e vagas), senão a linha aparece sem chip de vaga.
const janela = { limit: 50, offset: 0 };

// O corpo vem de `contratos/bff/fila.json`, gravado pela API de verdade (doc 101, A2).
const fila = contrato<WaitlistData>('fila', 'lista');

describe('fetchWaitlist', () => {
	it('o segmento da sidebar viaja como ?prio= (filtro no servidor)', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { waitlist: [], professionals: [] }));
		await fetchWaitlist(event, { ...janela, prio: 'urgente' });
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/waitlist?limit=50&offset=0&prio=urgente');
	});

	it('"todas" NÃO vira filtro (é a ausência dele)', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { waitlist: [], professionals: [] }));
		await fetchWaitlist(event, { ...janela, prio: 'todas' });
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/waitlist?limit=50&offset=0');
	});

	it('200 → a fila e os profissionais da barra', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, fila));
		const r = await fetchWaitlist(event, janela);
		expect(r.status).toBe(200);
		expect(r.data?.waitlist).toHaveLength(fila.waitlist.length);
		expect(r.data?.professionals).toHaveLength(fila.professionals.length);
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/waitlist?limit=50&offset=0');
	});

	it('erro da API → data nula com o status preservado', async () => {
		api.apiFetch.mockResolvedValueOnce(res(403));
		expect(await fetchWaitlist(event, janela)).toEqual({ status: 403, data: null });
	});

	it('falha de rede → status 0, sem estourar', async () => {
		api.apiFetch.mockRejectedValueOnce(new Error('boom'));
		expect(await fetchWaitlist(event, janela)).toEqual({ status: 0, data: null });
	});
});

describe('fetchSlots', () => {
	it('200 → as vagas do item, com o id escapado no caminho', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { slots: [{ date: '2026-07-21', start: 540 }] }));
		const r = await fetchSlots(event, 'e1');
		expect(r.data?.slots).toHaveLength(1);
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/waitlist/e1/slots');
	});

	it('id perigoso é escapado (não escapa do recurso)', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { slots: [] }));
		await fetchSlots(event, '../appointments');
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/waitlist/..%2Fappointments/slots');
	});

	it('erro vira data null (o modal mostra o vazio, não estoura)', async () => {
		api.apiFetch.mockResolvedValueOnce(res(404));
		expect((await fetchSlots(event, 'e1')).data).toBeNull();
	});

	it('falha de rede também degrada para null', async () => {
		api.apiFetch.mockRejectedValueOnce(new Error('boom'));
		expect(await fetchSlots(event, 'e1')).toEqual({ status: 0, data: null });
	});
});

describe('fetchAllSlots', () => {
	it('200 → o mapa entry_id → vagas do motor em lote', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { slots_by_entry: { e1: [{ start: 540 }], e2: [] } }));
		const r = await fetchAllSlots(event, janela);
		expect(api.apiFetch.mock.calls[0][1]).toBe('/api/waitlist/slots?limit=50&offset=0');
		expect(r.data?.slots_by_entry.e1).toHaveLength(1);
	});

	it('erro/rede degrada para data null (a lista fica sem a vaga, não estoura)', async () => {
		api.apiFetch.mockResolvedValueOnce(res(502));
		expect((await fetchAllSlots(event, janela)).data).toBeNull();
		api.apiFetch.mockRejectedValueOnce(new Error('boom'));
		expect(await fetchAllSlots(event, janela)).toEqual({ status: 0, data: null });
	});
});

describe('escrita — delega ao mutate no verbo/rota certos', () => {
	it('enqueueEntry: POST /api/waitlist com o corpo do contrato', async () => {
		await enqueueEntry(event, {
			patient_id: 'pat1',
			prio: 'alta',
			janela: 'manha',
			professional_ids: ['p1'],
			rules: [{ tipo: 'semana', dows: [1], data: null, periodos: [['09:00', '11:00']] }]
		});
		const [, path, method, body] = mut.mutate.mock.calls[0];
		expect(path).toBe('/api/waitlist');
		expect(method).toBe('POST');
		expect(body).toMatchObject({ patient_id: 'pat1', prio: 'alta', janela: 'manha' });
		expect(body.rules[0].tipo).toBe('semana');
	});

	it('updateEntry: PATCH /api/waitlist/:id (id escapado)', async () => {
		await updateEntry(event, 'e1', { prio: 'urgente' });
		const [, path, method, body] = mut.mutate.mock.calls[0];
		expect(path).toBe('/api/waitlist/e1');
		expect(method).toBe('PATCH');
		expect(body).toEqual({ prio: 'urgente' });
	});

	it('dequeueEntry: DELETE /api/waitlist/:id sem corpo', async () => {
		await dequeueEntry(event, 'e1');
		const [, path, method, body] = mut.mutate.mock.calls[0];
		expect(path).toBe('/api/waitlist/e1');
		expect(method).toBe('DELETE');
		expect(body).toBeUndefined();
	});

	it('convertEntry: POST /api/waitlist/:id/convert com o corpo do agendamento', async () => {
		await convertEntry(event, 'e1', {
			starts_at: '2026-07-21T12:00:00.000Z',
			professional_id: 'p1',
			appointment_type_id: 't1'
		});
		const [, path, method, body] = mut.mutate.mock.calls[0];
		expect(path).toBe('/api/waitlist/e1/convert');
		expect(method).toBe('POST');
		expect(body).toMatchObject({ professional_id: 'p1', appointment_type_id: 't1' });
	});

	// O horário foi tomado no meio-tempo → o 422 schedule_conflict volta pela conversão.
	it('convertEntry propaga o schedule_conflict do agendamento', async () => {
		mut.mutate.mockResolvedValueOnce({
			ok: false,
			status: 422,
			code: 'schedule_conflict',
			error: 'Esse horário sobrepõe outro agendamento.'
		});
		const r = await convertEntry(event, 'e1', {
			starts_at: '2026-07-21T12:00:00.000Z',
			professional_id: 'p1',
			appointment_type_id: 't1'
		});
		expect(r.code).toBe('schedule_conflict');
	});
});

// AN-12 (doc 64): o "quem cabe aqui" do drawer — a vaga que abriu pergunta à fila.
describe('fetchCandidates', () => {
	const slot = {
		professional_id: 'p1',
		starts_at: '2026-07-21T12:00:00Z',
		ends_at: '2026-07-21T12:50:00Z'
	};

	it('monta a query com o slot inteiro (profissional + janela)', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { candidates: [] }));
		await fetchCandidates(event, slot);
		expect(api.apiFetch.mock.calls[0][1]).toBe(
			'/api/waitlist/candidates?professional_id=p1&starts_at=2026-07-21T12%3A00%3A00Z&ends_at=2026-07-21T12%3A50%3A00Z'
		);
	});

	it('200 → os candidatos', async () => {
		api.apiFetch.mockResolvedValueOnce(res(200, { candidates: [{ id: 'e1' }] }));
		const r = await fetchCandidates(event, slot);
		expect(r.status).toBe(200);
		expect(r.data?.candidates).toHaveLength(1);
	});

	it('erro HTTP → data null', async () => {
		api.apiFetch.mockResolvedValueOnce(res(403));
		const r = await fetchCandidates(event, slot);
		expect(r).toEqual({ status: 403, data: null });
	});

	it('rede fora → status 0, sem estourar', async () => {
		api.apiFetch.mockRejectedValueOnce(new Error('rede'));
		const r = await fetchCandidates(event, slot);
		expect(r).toEqual({ status: 0, data: null });
	});
});

// O contrato com a API (doc 101, A2).
//
// A **vaga** (`/slots`) fica de fora da fixture, e é decisão: o `SlotFinder` varre a partir de
// AGORA, então as datas que ele devolve mudam com o dia em que a suíte roda — a fixture ficaria
// suja todo dia e o gate viraria ruído em uma semana. Aquele corpo segue escrito à mão aqui.
describe('contrato com a API', () => {
	it('a resposta traz a fila, o diretório, o hoje do servidor, a página e as contagens', () => {
		exigirCampos(
			fila,
			['waitlist', 'professionals', 'today', 'page', 'counts'],
			'fila/lista'
		);
	});

	it('o item da fila traz o que a linha desenha', () => {
		exigirCampos(
			primeiro(fila.waitlist, 'fila/lista → waitlist'),
			[
				'id',
				'prio',
				'janela',
				'obs',
				'professional_ids',
				'dias_na_fila',
				'rules',
				'patient',
				'inserted_at'
			],
			'fila/lista → waitlist[0]'
		);
	});

	// `dias_na_fila` é derivado no SERVIDOR a partir de `inserted_at`, no fuso da clínica
	// (ADR-009). Se ele sumisse, a coluna "espera" passaria a mostrar nada — e recalculá-lo no
	// browser é justamente o que a decisão proíbe.
	it('a espera vem calculada do servidor, não do browser', () => {
		expect(typeof primeiro(fila.waitlist, 'fila/lista → waitlist').dias_na_fila).toBe('number');
	});

	it('a regra de disponibilidade traz as quatro chaves que o editor mexe', () => {
		exigirCampos(
			primeiro(primeiro(fila.waitlist, 'fila/lista').rules, 'fila/lista → rules'),
			['tipo', 'dows', 'data', 'periodos'],
			'fila/lista → waitlist[0].rules[0]'
		);
	});

	it('o paciente da fila é a projeção enxuta, com o agregado de faltas', () => {
		exigirCampos(
			primeiro(fila.waitlist, 'fila/lista').patient,
			['id', 'nome', 'tel', 'ativo', 'faltas'],
			'fila/lista → waitlist[0].patient'
		);
	});
});
