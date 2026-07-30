import { describe, it, expect, vi, beforeEach } from 'vitest';

const apiFetch = vi.fn();
vi.mock('./api', () => ({ apiFetch: (...args: unknown[]) => apiFetch(...args) }));

import {
	fetchProfessionals,
	fetchProfessional,
	createProfessional,
	updateProfessional,
	deactivateProfessional,
	updateProfessionalHours,
	createProfessionalException,
	deleteProfessionalException,
	parseProfessionalForm,
	parseExceptions,
	parseIds,
	syncProfessionalExceptions,
	applyActiveState,
	runProfessionalSave,
	type ExceptionInput
} from './professionals';

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

const event = {} as never;
beforeEach(() => apiFetch.mockReset());

describe('fetchProfessionals', () => {
	it('200 → data', async () => {
		apiFetch.mockResolvedValueOnce(json({ professionals: [{ id: 'p1' }], clinic_hours: [] }));
		const r = await fetchProfessionals(event);
		expect(r.status).toBe(200);
		expect(r.data?.professionals).toHaveLength(1);
	});
	it('erro → data null', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 502 }));
		expect(await fetchProfessionals(event)).toEqual({ status: 502, data: null });
	});
	it('exceção de rede → status 0', async () => {
		apiFetch.mockRejectedValueOnce(new Error('down'));
		expect((await fetchProfessionals(event)).data).toBeNull();
	});
});

describe('fetchProfessional', () => {
	it('200 → professional', async () => {
		apiFetch.mockResolvedValueOnce(json({ professional: { id: 'p1', nome: 'X' } }));
		expect((await fetchProfessional(event, 'p1')).professional?.nome).toBe('X');
	});
	it('404 → null', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 404 }));
		expect((await fetchProfessional(event, 'p1')).professional).toBeNull();
	});
});

describe('createProfessional', () => {
	it('201 → devolve o id criado', async () => {
		apiFetch.mockResolvedValueOnce(json({ professional: { id: 'new-id' } }, 201));
		const r = await createProfessional(event, { nome: 'Nova' });
		expect(r.ok).toBe(true);
		expect(r.id).toBe('new-id');
	});
	it('422 → ok false com mensagem', async () => {
		apiFetch.mockResolvedValueOnce(json({ error: 'invalid' }, 422));
		const r = await createProfessional(event, { nome: '' });
		expect(r.ok).toBe(false);
		expect(r.error).toBeTruthy();
	});
});

describe('mutações simples', () => {
	it('update / deactivate / hours / exception chamam a API e propagam ok', async () => {
		apiFetch.mockResolvedValue(new Response('', { status: 200 }));
		expect((await updateProfessional(event, 'p1', { nome: 'X' })).ok).toBe(true);
		expect((await deactivateProfessional(event, 'p1')).ok).toBe(true);
		expect((await updateProfessionalHours(event, 'p1', [{ dow: 1, modo: 'herda', periods: [] }])).ok).toBe(true);
		expect((await createProfessionalException(event, 'p1', { data: '2026-08-10', nome: 'F', tipo: 'fechado', periods: [] })).ok).toBe(true);
		expect((await deleteProfessionalException(event, 'p1', 'e1')).ok).toBe(true);
	});
});

describe('parseProfessionalForm', () => {
	const days = JSON.stringify([{ dow: 1, modo: 'herda', periods: [] }]);

	it('ok com nome e horário', () => {
		const r = parseProfessionalForm(JSON.stringify({ nome: 'Marina', segue_horario_clinica: true }), days);
		expect(r.ok).toBe(true);
	});
	it('nome vazio → erro', () => {
		const r = parseProfessionalForm(JSON.stringify({ nome: '  ' }), days);
		expect(r).toEqual({ ok: false, error: 'O nome é obrigatório.' });
	});
	it('ficha ilegível → erro', () => {
		expect(parseProfessionalForm('{quebrado', days).ok).toBe(false);
	});
	it('não seguindo sem dia custom → exige um dia de atendimento', () => {
		const r = parseProfessionalForm(
			JSON.stringify({ nome: 'Marina', segue_horario_clinica: false }),
			JSON.stringify([{ dow: 1, modo: 'fechado', periods: [] }])
		);
		expect(r).toEqual({ ok: false, error: 'Defina ao menos um dia de atendimento.' });
	});
	it('não seguindo com um dia custom → ok', () => {
		const r = parseProfessionalForm(
			JSON.stringify({ nome: 'Marina', segue_horario_clinica: false }),
			JSON.stringify([{ dow: 1, modo: 'custom', periods: [['09:00', '10:00']] }])
		);
		expect(r.ok).toBe(true);
	});
	it('days não-array → erro', () => {
		expect(parseProfessionalForm(JSON.stringify({ nome: 'X' }), '{}').ok).toBe(false);
	});
});

describe('parseExceptions / parseIds', () => {
	it('exceções: normaliza id nulo e periods', () => {
		const raw = JSON.stringify([
			{ id: 'e1', data: '2026-08-10', nome: 'Férias', tipo: 'fechado', periods: [] },
			{ id: null, data: '2026-08-11', nome: 'Meio', tipo: 'horario', periods: [['08:00', '12:00']] }
		]);
		const parsed = parseExceptions(raw);
		expect(parsed).toHaveLength(2);
		expect(parsed[1].id).toBeNull();
	});
	it('JSON inválido → []', () => {
		expect(parseExceptions('{')).toEqual([]);
		expect(parseIds('{')).toEqual([]);
	});
	it('ids: só strings', () => {
		expect(parseIds(JSON.stringify(['a', 1, 'b']))).toEqual(['a', 'b']);
	});
});

describe('runProfessionalSave', () => {
	const goodFicha = JSON.stringify({ nome: 'Marina', segue_horario_clinica: true });
	const goodDays = JSON.stringify([{ dow: 1, modo: 'herda', periods: [] }]);

	function form(fields: Record<string, string>): FormData {
		const fd = new FormData();
		for (const [k, v] of Object.entries(fields)) fd.set(k, v);
		return fd;
	}

	it('fluxo feliz: persiste, grava horas e devolve ok', async () => {
		apiFetch.mockResolvedValue(new Response('', { status: 200 })); // updateProfessionalHours
		const persist = vi.fn(async () => ({ ok: true, status: 201, id: 'new-id' }));

		const res = await runProfessionalSave(
			event,
			form({ ficha: goodFicha, days: goodDays, exceptions: '[]', ativo: 'true' }),
			{ persist, originalActive: true, originalExceptionIds: [] }
		);

		expect(res).toEqual({ ok: true });
		expect(persist).toHaveBeenCalledWith(expect.objectContaining({ nome: 'Marina' }));
	});

	it('validação falha → ok:false 400 sem persistir', async () => {
		const persist = vi.fn();
		const res = await runProfessionalSave(
			event,
			form({ ficha: JSON.stringify({ nome: '' }), days: goodDays }),
			{ persist, originalActive: true, originalExceptionIds: [] }
		);
		expect(res).toMatchObject({ ok: false, status: 400 });
		expect(persist).not.toHaveBeenCalled();
	});

	it('persist recusado → propaga o status', async () => {
		const persist = vi.fn(async () => ({ ok: false, status: 403, error: 'x' }));
		const res = await runProfessionalSave(event, form({ ficha: goodFicha, days: goodDays }), {
			persist,
			originalActive: true,
			originalExceptionIds: []
		});
		expect(res).toMatchObject({ ok: false, status: 403 });
	});

	it('grade recusada (422) → propaga', async () => {
		apiFetch.mockResolvedValueOnce(json({ error: 'invalid' }, 422)); // updateProfessionalHours
		const persist = vi.fn(async () => ({ ok: true, status: 201, id: 'id' }));
		const res = await runProfessionalSave(
			event,
			form({ ficha: goodFicha, days: goodDays, exceptions: '[]' }),
			{ persist, originalActive: true, originalExceptionIds: [] }
		);
		expect(res).toMatchObject({ ok: false, status: 422 });
	});
});

describe('applyActiveState', () => {
	it('sem mudança → no-op sem tocar na API', async () => {
		const r = await applyActiveState(event, 'p1', true, true);
		expect(r.ok).toBe(true);
		expect(apiFetch).not.toHaveBeenCalled();
	});
	it('desativar chama deactivate', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 200 }));
		await applyActiveState(event, 'p1', false, true);
		expect(apiFetch).toHaveBeenCalledWith(event, expect.stringContaining('/deactivate'), expect.anything());
	});
	it('reativar chama reactivate', async () => {
		apiFetch.mockResolvedValueOnce(new Response('', { status: 200 }));
		await applyActiveState(event, 'p1', true, false);
		expect(apiFetch).toHaveBeenCalledWith(event, expect.stringContaining('/reactivate'), expect.anything());
	});
});

describe('syncProfessionalExceptions', () => {
	it('cria as novas e apaga as removidas', async () => {
		apiFetch.mockResolvedValue(new Response('', { status: 200 }));
		const desired: ExceptionInput[] = [
			{ id: 'keep', data: '2026-08-10', nome: 'A', tipo: 'fechado', periods: [] },
			{ id: null, data: '2026-08-12', nome: 'Nova', tipo: 'fechado', periods: [] }
		];
		const r = await syncProfessionalExceptions(event, 'p1', desired, ['keep', 'gone']);
		expect(r.ok).toBe(true);
		// 1 delete ('gone') + 1 create (a nova) = 2 chamadas
		expect(apiFetch).toHaveBeenCalledTimes(2);
	});
	it('para e devolve erro se uma operação falha', async () => {
		apiFetch.mockResolvedValueOnce(json({ error: 'invalid' }, 422));
		const r = await syncProfessionalExceptions(event, 'p1', [], ['gone']);
		expect(r.ok).toBe(false);
	});
});
