import { describe, it, expect, vi, beforeEach } from 'vitest';

const m = vi.hoisted(() => ({ apiFetch: vi.fn() }));
vi.mock('./api', () => m);

import { mutate, errorMessage, errorInfo } from './mutate';

// Resposta mínima com o shape que `mutate` consome (ok/status/json).
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

beforeEach(() => m.apiFetch.mockReset());

describe('errorInfo — a escada de erros', () => {
	it('403 → mensagem de permissão, sem code nem details', async () => {
		const info = await errorInfo(res(403));
		expect(info.error).toBe('Você não tem permissão para esta ação.');
		expect(info.code).toBeUndefined();
		expect(info.details).toBeUndefined();
	});

	it('404 → registro não encontrado', async () => {
		expect((await errorInfo(res(404))).error).toBe('Registro não encontrado.');
	});

	it('corpo não-JSON cai na mensagem genérica', async () => {
		expect((await errorInfo(res(500))).error).toBe('Não foi possível concluir a operação.');
	});

	// O ponto desta fatia: o `details` do 422 PRECISA sobreviver ao BFF. Sem ele o fluxo de
	// encaixe (código `schedule_conflict`, que vem com field:null) é inalcançável pela UI.
	it('422 propaga `code` e `details` — não achata tudo numa string', async () => {
		const info = await errorInfo(
			res(422, {
				error: 'invalid',
				code: 'schedule_conflict',
				details: [{ field: null, message: 'Esse horário sobrepõe outro agendamento.' }]
			})
		);

		expect(info.code).toBe('schedule_conflict');
		expect(info.details).toEqual([
			{ field: null, message: 'Esse horário sobrepõe outro agendamento.' }
		]);
	});

	// A mensagem do servidor é mais útil que a genérica — e no caso field:null é a ÚNICA
	// explicação que existe (não há campo para pintar de vermelho).
	it('422 usa a mensagem do primeiro detalhe como `error`', async () => {
		const info = await errorInfo(
			res(422, {
				error: 'invalid',
				code: 'outside_business_hours',
				details: [{ field: null, message: 'Fora do expediente do profissional.' }]
			})
		);
		expect(info.error).toBe('Fora do expediente do profissional.');
	});

	it('422 sem `details` mantém a mensagem genérica de sempre (compatibilidade)', async () => {
		const info = await errorInfo(res(422, { error: 'invalid' }));
		expect(info.error).toBe('Dados inválidos. Verifique os campos.');
		expect(info.details).toBeUndefined();
	});

	it('`details` malformado (não-array, item sem message) é ignorado, não derruba', async () => {
		expect((await errorInfo(res(422, { error: 'invalid', details: 'oops' }))).details).toBeUndefined();
		expect(
			(await errorInfo(res(422, { error: 'invalid', details: [{ field: 'nome' }] }))).details
		).toBeUndefined();
	});

	it('`code` não-string é ignorado', async () => {
		expect((await errorInfo(res(422, { error: 'invalid', code: 7 }))).code).toBeUndefined();
	});
});

// Contrato antigo intacto: os BFFs de Pacientes/Profissionais chamam `errorMessage` direto.
describe('errorMessage — contrato preservado para os chamadores existentes', () => {
	it('continua devolvendo uma string', async () => {
		await expect(errorMessage(res(403))).resolves.toBe('Você não tem permissão para esta ação.');
		await expect(errorMessage(res(422, { error: 'invalid' }))).resolves.toBe(
			'Dados inválidos. Verifique os campos.'
		);
	});
});

describe('mutate', () => {
	it('2xx → ok, sem erro', async () => {
		m.apiFetch.mockResolvedValueOnce(res(204));
		expect(await mutate(event, '/api/x', 'POST')).toEqual({ ok: true, status: 204 });
	});

	it('422 → ok:false COM code e details a bordo', async () => {
		m.apiFetch.mockResolvedValueOnce(
			res(422, {
				error: 'invalid',
				code: 'schedule_conflict',
				details: [{ field: null, message: 'Esse horário sobrepõe outro agendamento.' }]
			})
		);

		const r = await mutate(event, '/api/appointments', 'POST', { starts_at: 'x' });
		expect(r.ok).toBe(false);
		expect(r.status).toBe(422);
		expect(r.code).toBe('schedule_conflict');
		expect(r.details?.[0].message).toBe('Esse horário sobrepõe outro agendamento.');
	});

	it('falha de rede → status 0 e mensagem de conexão', async () => {
		m.apiFetch.mockRejectedValueOnce(new Error('boom'));
		const r = await mutate(event, '/api/x', 'POST');
		expect(r).toEqual({ ok: false, status: 0, error: 'Falha de conexão com o servidor.' });
	});
});
