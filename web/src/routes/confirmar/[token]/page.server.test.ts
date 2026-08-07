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

/**
 * O `load` do Kit é tipado como `void | PageData` (há rotas que não devolvem nada), e este aqui
 * sempre devolve. O cast tira o `void` para os testes poderem ler os campos — sem ele, o
 * `svelte-check` reprova cada `out.quando`.
 */
const carregar = async (event: Parameters<typeof load>[0]) =>
	(await load(event)) as Exclude<Awaited<ReturnType<typeof load>>, void>;

// A página do paciente (doc 52 §5). Não tem sessão: o que autoriza é o token, e o BFF fala com a
// API **sem** `apiFetch` porque não há cookie para repassar.

function res(status: number, body?: unknown) {
	return { ok: status >= 200 && status < 300, status, json: async () => body };
}

// 10/08/2026 é uma segunda-feira; 12:00Z = 09:00 em São Paulo.
const resumo = {
	clinica: 'Clínica da Ana',
	clinica_telefone: '(61) 99946-6274',
	paciente: 'Maria',
	data: '10/08/2026',
	hora: '09:00',
	inicio: '2026-08-10T12:00:00Z',
	fim: '2026-08-10T12:50:00Z',
	timezone: 'America/Sao_Paulo',
	ativa: true,
	resposta: null,
	respondido_em: null
};

let fetchMock: ReturnType<typeof vi.fn>;

beforeEach(() => {
	fetchMock = vi.fn();
});

// O evento do SvelteKit como ele chega de verdade: com `getClientAddress`, que é o que carrega o
// IP do paciente até a API, e com `request.headers` — de onde sai o `user-agent` que decide a
// forma do link do Google.
function evento(token: string, resposta?: string, userAgent?: string) {
	return {
		params: { token },
		fetch: fetchMock,
		getClientAddress: () => '203.0.113.77',
		request: {
			headers: new Headers(userAgent ? { 'user-agent': userAgent } : {}),
			formData: async () => new Map([['resposta', resposta ?? '']]) as unknown as FormData
		}
	} as never;
}

const UA_ANDROID =
	'Mozilla/5.0 (Linux; Android 14; SM-S911B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

describe('load', () => {
	it('marca o Android pelo `user-agent`, que é quem escolhe a forma do link do Google', async () => {
		// A escolha é do SERVIDOR: feita no browser, o SSR pintaria um `href` e a hidratação
		// trocaria por outro, debaixo do dedo de quem já ia tocar no botão.
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		expect((await carregar(evento('tk', undefined, UA_ANDROID))).android).toBe(true);
	});

	it('sem `user-agent` de Android o link fica na forma normal', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		expect((await carregar(evento('tk'))).android).toBe(false);
	});

	it('200 → devolve o resumo da sessão', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		const out = await carregar(evento('tk'));

		expect(out.resumo).toEqual(resumo);
		expect(out.status).toBe(200);
		expect(fetchMock.mock.calls[0][0]).toBe('http://api/api/reply/tk');
	});

	it('token vencido devolve 410 como DADO, não como erro', async () => {
		// A página de erro padrão fala com um usuário do sistema ("volte ao painel"), e quem está
		// aqui não tem painel.
		fetchMock.mockResolvedValueOnce(res(410));

		const out = await carregar(evento('tk'));

		expect(out).toEqual({ resumo: null, status: 410, quando: null, android: false });
	});

	it('token com caractere especial é escapado na URL', async () => {
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		await load(evento('a/b c'));

		expect(fetchMock.mock.calls[0][0]).toBe('http://api/api/reply/a%2Fb%20c');
	});

	it('leva o IP do paciente à API — sem ele, todos dividem um balde de rate limit só', async () => {
		// Esta chamada não passa por `apiFetch` (não há sessão), e era por isso que perdia o
		// `x-forwarded-for`. Sem ator, o IP é a única chave que a API tem: um visitante em laço
		// derrubava a confirmação de todos os pacientes (doc 68, causa B).
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		await load(evento('tk'));

		const [, init] = fetchMock.mock.calls[0];
		expect((init.headers as Headers).get('x-forwarded-for')).toBe('203.0.113.77');
		expect((init.headers as Headers).get('accept')).toBe('application/json');
	});

	it('a data vira leitura humana no SERVIDOR, e não no componente', async () => {
		// O relógio do browser é o do paciente — pode estar em outro fuso e pode estar errado —, e
		// o que a hidratação calculasse divergiria do que o SSR pintou. Aqui a conta é uma só.
		fetchMock.mockResolvedValueOnce(res(200, resumo));

		const out = await carregar(evento('tk'));

		expect(out.quando?.extenso).toMatch(/^segunda-feira, 10 de agosto/);
		expect(out.quando?.hora).toBe('09:00');
	});

	it('sem instante da API, `quando` é null — a tela cai no "DD/MM/AAAA" congelado', async () => {
		// Não é hipótese: mensagem antiga, gravada antes de a API passar a devolver `inicio`,
		// continua respondendo por 30 dias.
		fetchMock.mockResolvedValueOnce(res(200, { ...resumo, inicio: null, timezone: null }));

		const out = await carregar(evento('tk'));

		expect(out.quando).toBeNull();
		expect(out.resumo?.data).toBe('10/08/2026');
	});

	it('rede caída não derruba a página', async () => {
		fetchMock.mockRejectedValueOnce(new Error('offline'));

		const out = await carregar(evento('tk'));

		expect(out).toEqual({ resumo: null, status: 0, quando: null, android: false });
	});
});

describe('action', () => {
	it('encaminha a resposta e devolve o novo estado', async () => {
		const respondido = { ...resumo, resposta: 'confirmou', respondido_em: '2026-08-10T18:41:00Z' };
		fetchMock.mockResolvedValueOnce(res(200, respondido));

		const out = await actions.default(evento('tk', 'confirmou'));

		expect(out).toMatchObject({ resumo: respondido });
		expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({ resposta: 'confirmou' });
	});

	it('falha vira mensagem para o paciente, não erro técnico', async () => {
		fetchMock.mockResolvedValueOnce(res(422));

		const out = (await actions.default(evento('tk', 'talvez'))) as {
			status: number;
			data: { error: string };
		};

		expect(out.status).toBe(422);
		expect(out.data.error).toMatch(/Tente novamente/);
	});
});
