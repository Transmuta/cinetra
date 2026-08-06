import { describe, it, expect, vi, beforeEach } from 'vitest';

// `headersDeContexto` é o de verdade (não é mock): é justamente ele que este arquivo precisa provar
// que está sendo chamado.
const api = vi.hoisted(() => ({
	apiBase: () => 'http://api',
	headersDeContexto: (event: { getClientAddress?: () => string }, init?: HeadersInit) => {
		const headers = new Headers(init);
		const ip = event.getClientAddress?.();
		if (ip) headers.set('x-forwarded-for', ip);
		return headers;
	}
}));
vi.mock('$lib/server/api', () => api);

import { load, actions } from './+page.server';

// O descadastro pelo rodapé do e-mail (doc 52 §10). Como a página de confirmação: sem sessão,
// autorizado só pelo token — e com uma regra a mais, que é a que este arquivo existe para prender.

function res(status: number, body?: unknown) {
	return { ok: status >= 200 && status < 300, status, json: async () => body };
}

const resumo = { clinica: 'Clínica da Ana', canal: 'email', descadastrado: false };

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
	fetchMock = vi.fn();
});

function evento(token: string) {
	return {
		params: { token },
		fetch: fetchMock,
		getClientAddress: () => '203.0.113.77'
	} as never;
}

describe('load', () => {
	it('200 → devolve o estado da lista', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		const out = await load(evento('tk'));

		expect(out).toEqual({ resumo, status: 200 });
		expect(fetchMock.mock.calls[0][0]).toBe('http://api/api/opt-out/tk');
	});

	it('ABRIR a página não descadastra — o GET não pode ter efeito', async () => {
		// A regra que dá nome ao arquivo. Antivírus corporativo e pré-visualização de webmail
		// visitam todo link de todo e-mail: com efeito no `load`, o paciente sairia da lista sem
		// nunca ter clicado, e o sintoma apareceria meses depois.
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		await load(evento('tk'));

		expect(fetchMock).toHaveBeenCalledTimes(1);
		expect(fetchMock.mock.calls[0][1]?.method ?? 'GET').toBe('GET');
	});

	it('token vencido devolve 410 como DADO, não como erro', async () => {
		fetchMock.mockResolvedValueOnce(res(410));

		const out = await load(evento('tk'));

		expect(out).toEqual({ resumo: null, status: 410 });
	});

	it('token com caractere especial é escapado na URL', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		await load(evento('a/b c'));

		expect(fetchMock.mock.calls[0][0]).toBe('http://api/api/opt-out/a%2Fb%20c');
	});

	it('leva o IP do paciente à API — sem ele, todos dividem um balde de rate limit só', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		await load(evento('tk'));

		const [, init] = fetchMock.mock.calls[0];
		expect((init.headers as Headers).get('x-forwarded-for')).toBe('203.0.113.77');
		expect((init.headers as Headers).get('accept')).toBe('application/json');
	});

	it('rede caída não derruba a página', async () => {
		fetchMock.mockRejectedValueOnce(new Error('offline'));

		const out = await load(evento('tk'));

		expect(out).toEqual({ resumo: null, status: 0 });
	});
});

describe('action', () => {
	it('o POST é quem descadastra', async () => {
		const fora = { ...resumo, descadastrado: true };
		fetchMock.mockResolvedValueOnce(res(200, fora));

		const out = await actions.default(evento('tk'));

		expect(out).toEqual({ resumo: fora });
		expect(fetchMock.mock.calls[0][1].method).toBe('POST');
	});

	it('falha vira mensagem para o paciente, não erro técnico', async () => {
		fetchMock.mockResolvedValueOnce(res(500));

		const out = (await actions.default(evento('tk'))) as {
			status: number;
			data: { error: string };
		};

		expect(out.status).toBe(500);
		expect(out.data.error).toMatch(/Tente novamente/);
	});
});
