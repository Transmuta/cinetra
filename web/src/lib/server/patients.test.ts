import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiFetch = vi.fn();
vi.mock('./api', () => ({ apiFetch: (...args: unknown[]) => apiFetch(...args) }));

import {
	patientsQuery,
	fetchPatients,
	fetchPatient,
	fetchPatientHistory,
	createPatient,
	updatePatient,
	deactivatePatient,
	reactivatePatient,
	parsePatientForm,
	runPatientSave
} from './patients';

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

const event = {} as never;
beforeEach(() => apiFetch.mockReset());

describe('patientsQuery', () => {
	it('sem parâmetros → string vazia', () => {
		expect(patientsQuery()).toBe('');
	});
	it('monta busca, segmento e recorte', () => {
		expect(patientsQuery({ q: 'mari', filter: 'inativos', limit: 50, offset: 100 })).toBe(
			'?q=mari&filter=inativos&limit=50&offset=100'
		);
	});
	it('omite o que já é default da API (filter=todos, offset=0)', () => {
		expect(patientsQuery({ filter: 'todos', offset: 0, limit: 50 })).toBe('?limit=50');
	});
});

describe('fetchPatients', () => {
	it('200 → data', async () => {
		apiFetch.mockResolvedValueOnce(json({ patients: [{ id: 'pac1' }] }));
		const r = await fetchPatients(event);
		expect(r.status).toBe(200);
		expect(r.data?.patients).toHaveLength(1);
	});

	it('repassa o recorte na query string', async () => {
		apiFetch.mockResolvedValueOnce(json({ patients: [] }));
		await fetchPatients(event, { q: 'mari', filter: 'ativos', limit: 50, offset: 50 });

		expect(apiFetch).toHaveBeenCalledWith(
			event,
			'/api/patients?q=mari&filter=ativos&limit=50&offset=50',
			expect.anything()
		);
	});
	it('erro → data null', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 502 }));
		expect(await fetchPatients(event)).toEqual({ status: 502, data: null });
	});
	it('exceção de rede → status 0', async () => {
		apiFetch.mockRejectedValueOnce(new Error('down'));
		expect((await fetchPatients(event)).data).toBeNull();
	});
});

describe('fetchPatient', () => {
	it('200 → patient', async () => {
		apiFetch.mockResolvedValueOnce(json({ patient: { id: 'pac1', nome: 'Mari' } }));
		expect((await fetchPatient(event, 'pac1')).patient?.nome).toBe('Mari');
	});
	it('404 → null', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 404 }));
		expect((await fetchPatient(event, 'pac1')).patient).toBeNull();
	});
	it('exceção de rede → status 0 / null', async () => {
		apiFetch.mockRejectedValueOnce(new Error('down'));
		expect((await fetchPatient(event, 'pac1')).patient).toBeNull();
	});
});

describe('createPatient', () => {
	it('201 → devolve o id criado', async () => {
		apiFetch.mockResolvedValueOnce(json({ patient: { id: 'new-id' } }, 201));
		const r = await createPatient(event, { nome: 'Nova' });
		expect(r.ok).toBe(true);
		expect(r.id).toBe('new-id');
	});
	it('422 → ok false com mensagem', async () => {
		apiFetch.mockResolvedValueOnce(json({ error: 'invalid' }, 422));
		const r = await createPatient(event, { nome: '' });
		expect(r.ok).toBe(false);
		expect(r.error).toBeTruthy();
	});
	it('exceção de rede → ok false', async () => {
		apiFetch.mockRejectedValueOnce(new Error('down'));
		expect((await createPatient(event, { nome: 'X' })).ok).toBe(false);
	});
});

describe('mutações simples', () => {
	it('update / deactivate / reactivate chamam a API e propagam ok', async () => {
		apiFetch.mockResolvedValue(new Response('', { status: 200 }));
		expect((await updatePatient(event, 'pac1', { nome: 'X' })).ok).toBe(true);
		expect((await deactivatePatient(event, 'pac1')).ok).toBe(true);
		expect((await reactivatePatient(event, 'pac1')).ok).toBe(true);
		expect(apiFetch).toHaveBeenCalledWith(event, expect.stringContaining('/deactivate'), expect.anything());
		expect(apiFetch).toHaveBeenCalledWith(event, expect.stringContaining('/reactivate'), expect.anything());
	});
});

describe('parsePatientForm', () => {
	it('ok com nome', () => {
		expect(parsePatientForm(JSON.stringify({ nome: 'Mariana' })).ok).toBe(true);
	});
	it('nome vazio → erro', () => {
		expect(parsePatientForm(JSON.stringify({ nome: '  ' }))).toEqual({
			ok: false,
			error: 'O nome é obrigatório.'
		});
	});
	it('ficha ilegível → erro', () => {
		expect(parsePatientForm('{quebrado').ok).toBe(false);
	});
});

describe('runPatientSave', () => {
	function form(fields: Record<string, string>): FormData {
		const fd = new FormData();
		for (const [k, v] of Object.entries(fields)) fd.set(k, v);
		return fd;
	}

	it('fluxo feliz: valida e persiste', async () => {
		const persist = vi.fn(async () => ({ ok: true, status: 201, id: 'new-id' }));
		const res = await runPatientSave(event, form({ ficha: JSON.stringify({ nome: 'Mariana' }) }), { persist });
		expect(res).toEqual({ ok: true });
		expect(persist).toHaveBeenCalledWith(expect.objectContaining({ nome: 'Mariana' }));
	});

	it('validação falha → 400 sem persistir', async () => {
		const persist = vi.fn();
		const res = await runPatientSave(event, form({ ficha: JSON.stringify({ nome: '' }) }), { persist });
		expect(res).toMatchObject({ ok: false, status: 400 });
		expect(persist).not.toHaveBeenCalled();
	});

	it('persist recusado → propaga o status', async () => {
		const persist = vi.fn(async () => ({ ok: false, status: 403, error: 'x' }));
		const res = await runPatientSave(event, form({ ficha: JSON.stringify({ nome: 'Mari' }) }), { persist });
		expect(res).toMatchObject({ ok: false, status: 403 });
	});
});

// C13 / Frente 7. A ficha inteira não pode cair por causa da seção de baixo: falha de rede ou 500
// no histórico degrada para lista vazia, não para erro de página.
describe('fetchPatientHistory', () => {
	it('200 → sessões e o aviso de corte', async () => {
		apiFetch.mockResolvedValueOnce(
			json({ sessions: [{ id: 'att1', status: 'faltou' }], more: true })
		);

		const r = await fetchPatientHistory(event, 'pac1');

		expect(r.sessions).toHaveLength(1);
		expect(r.more).toBe(true);
		expect(apiFetch.mock.calls[0][1]).toBe('/api/patients/pac1/history');
	});

	// doc 56: a API passou a devolver duas listas. O que ainda vai acontecer não é histórico — e
	// era ele que encabeçava o cartão, com o selo "Previsto".
	it('200 → as próximas vêm separadas do histórico', async () => {
		apiFetch.mockResolvedValueOnce(
			json({
				sessions: [{ id: 'att1' }],
				more: false,
				upcoming: [{ id: 'att2' }, { id: 'att3' }],
				upcoming_more: true
			})
		);

		const r = await fetchPatientHistory(event, 'pac1');

		expect(r.sessions).toHaveLength(1);
		expect(r.upcoming).toHaveLength(2);
		expect(r.upcomingMore).toBe(true);
	});

	// API antiga (ou 200 sem as chaves novas) não pode virar `undefined.length` na ficha.
	it('resposta sem as chaves novas degrada para listas vazias', async () => {
		apiFetch.mockResolvedValueOnce(json({ sessions: [{ id: 'att1' }], more: false }));

		const r = await fetchPatientHistory(event, 'pac1');

		expect(r.upcoming).toEqual([]);
		expect(r.upcomingMore).toBe(false);
	});

	it('pede o tamanho de página que a ficha quer', async () => {
		apiFetch.mockResolvedValueOnce(json({ sessions: [], more: false }));
		await fetchPatientHistory(event, 'pac1', 8);
		expect(apiFetch.mock.calls[0][1]).toBe('/api/patients/pac1/history?limit=8');
	});

	it('erro → lista vazia (a ficha degrada, não quebra)', async () => {
		apiFetch.mockResolvedValueOnce(json({}, 500));
		expect(await fetchPatientHistory(event, 'pac1')).toEqual({
			status: 500,
			sessions: [],
			more: false,
			upcoming: [],
			upcomingMore: false
		});
	});

	it('id forjado não sai do caminho do recurso', async () => {
		apiFetch.mockResolvedValueOnce(json({ sessions: [], more: false }));
		await fetchPatientHistory(event, '../../admin');
		expect(apiFetch.mock.calls[0][1]).toBe('/api/patients/..%2F..%2Fadmin/history');
	});
});
