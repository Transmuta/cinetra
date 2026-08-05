import { describe, it, expect, vi, beforeEach } from 'vitest';

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

import { GET } from './+server';

/**
 * "Adicionar à agenda", na tela de confirmação do paciente.
 *
 * É uma rota, e não um `data:` no `href`, porque o Chrome bloqueia navegação de topo para `data:`
 * e o iOS não baixa Blob de forma confiável — as duas alternativas falham exatamente no aparelho
 * em que esta tela mais é aberta.
 */

const resumo = {
	clinica: 'Clínica Moving',
	clinica_telefone: '(61) 99946-6274',
	paciente: 'Ana',
	data: '05/08/2026',
	hora: '08:30',
	inicio: '2026-08-05T11:30:00Z',
	fim: '2026-08-05T12:20:00Z',
	timezone: 'America/Sao_Paulo',
	ativa: true,
	resposta: null,
	respondido_em: null
};

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
	fetchMock = vi.fn();
});

function res(status: number, body?: unknown) {
	return { ok: status >= 200 && status < 300, status, json: async () => body };
}

function evento(token = 'tk') {
	return {
		params: { token },
		fetch: fetchMock,
		getClientAddress: () => '203.0.113.77'
	} as never;
}

describe('GET /confirmar/[token]/sessao.ics', () => {
	it('devolve o evento como text/calendar, para o app de calendário abrir', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		const out = await GET(evento());
		const corpo = await out.text();

		expect(out.headers.get('content-type')).toContain('text/calendar');
		expect(out.headers.get('content-disposition')).toContain('sessao.ics');
		expect(corpo).toContain('BEGIN:VEVENT');
		expect(corpo).toContain('DTSTART:20260805T113000Z');
		expect(corpo).toContain('SUMMARY:Sessão na Clínica Moving');
	});

	it('não guarda o token no arquivo — ele pode acabar num calendário compartilhado', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		const corpo = await (await GET(evento('token-secreto'))).text();

		expect(corpo).not.toContain('token-secreto');
	});

	it('põe o telefone da clínica na descrição, que é a saída de quem não puder vir', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		const corpo = await (await GET(evento())).text();

		// Desdobra antes de procurar — é o que um leitor de `.ics` faz. A linha da descrição passa
		// de 75 octetos e o telefone cai partido em duas ("(6" / "1) 99946…"); procurá-lo no texto
		// cru reprovaria o arquivo justamente por ele estar CERTO.
		expect(corpo.replace(/\r\n /g, '')).toContain('(61) 99946-6274');
	});

	it('não é cacheado: a sessão pode ser remarcada depois', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		const out = await GET(evento());

		expect(out.headers.get('cache-control')).toContain('no-store');
	});

	it('sessão cancelada não vira evento', async () => {
		fetchMock.mockResolvedValueOnce(res(200, { ...resumo, ativa: false }));

		await expect(GET(evento())).rejects.toMatchObject({ status: 404 });
	});

	it('link inválido não vira evento', async () => {
		fetchMock.mockResolvedValueOnce(res(404));

		await expect(GET(evento())).rejects.toMatchObject({ status: 404 });
	});

	it('sem instante da API não há evento — inventar duração marcaria o dia errado', async () => {
		fetchMock.mockResolvedValueOnce(res(200, { ...resumo, inicio: null, fim: null }));

		await expect(GET(evento())).rejects.toMatchObject({ status: 404 });
	});

	it('repassa o IP do paciente — o rate limit da API não tem outra chave', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		await GET(evento());

		const headers = fetchMock.mock.calls[0][1].headers as Headers;
		expect(headers.get('x-forwarded-for')).toBe('203.0.113.77');
	});
});
