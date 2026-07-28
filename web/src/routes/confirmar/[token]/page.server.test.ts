import { describe, it, expect, vi, beforeEach } from 'vitest';

const api = vi.hoisted(() => ({ apiBase: () => 'http://api' }));
vi.mock('$lib/server/api', () => api);

import { load, actions } from './+page.server';

// A página do paciente (doc 52 §5). Não tem sessão: o que autoriza é o token, e o BFF fala com a
// API **sem** `apiFetch` porque não há cookie para repassar.

function res(status: number, body?: unknown) {
	return { ok: status >= 200 && status < 300, status, json: async () => body };
}

const resumo = {
	clinica: 'Clínica da Ana',
	paciente: 'Maria',
	data: '10/08/2026',
	hora: '09:00',
	resposta: null,
	respondidoEm: null
};

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
	fetchMock = vi.fn();
});

describe('load', () => {
	it('200 → devolve o resumo da sessão', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		const out = await load({ params: { token: 'tk' }, fetch: fetchMock } as never);

		expect(out).toEqual({ resumo, status: 200 });
		expect(fetchMock.mock.calls[0][0]).toBe('http://api/api/reply/tk');
	});

	it('token vencido devolve 410 como DADO, não como erro', async () => {
		// A página de erro padrão fala com um usuário do sistema ("volte ao painel"), e quem está
		// aqui não tem painel.
		fetchMock.mockResolvedValueOnce(res(410));

		const out = await load({ params: { token: 'tk' }, fetch: fetchMock } as never);

		expect(out).toEqual({ resumo: null, status: 410 });
	});

	it('token com caractere especial é escapado na URL', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		await load({ params: { token: 'a/b c' }, fetch: fetchMock } as never);

		expect(fetchMock.mock.calls[0][0]).toBe('http://api/api/reply/a%2Fb%20c');
	});

	it('rede caída não derruba a página', async () => {
		fetchMock.mockRejectedValueOnce(new Error('offline'));

		const out = await load({ params: { token: 'tk' }, fetch: fetchMock } as never);

		expect(out).toEqual({ resumo: null, status: 0 });
	});
});

describe('action', () => {
	function evento(resposta: string) {
		return {
			params: { token: 'tk' },
			fetch: fetchMock,
			request: { formData: async () => new Map([['resposta', resposta]]) as unknown as FormData }
		} as never;
	}

	it('encaminha a resposta e devolve o novo estado', async () => {
		const respondido = { ...resumo, resposta: 'confirmou', respondidoEm: '2026-08-10T18:41:00Z' };
		fetchMock.mockResolvedValueOnce(res(200, respondido));

		const out = await actions.default(evento('confirmou'));

		expect(out).toEqual({ resumo: respondido });
		expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ resposta: 'confirmou' });
	});

	it('falha vira mensagem para o paciente, não erro técnico', async () => {
		fetchMock.mockResolvedValueOnce(res(422));

		const out = (await actions.default(evento('talvez'))) as { status: number; data: { error: string } };

		expect(out.status).toBe(422);
		expect(out.data.error).toMatch(/Tente novamente/);
	});
});
