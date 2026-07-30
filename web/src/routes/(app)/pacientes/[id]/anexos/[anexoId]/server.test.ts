import { describe, it, expect, vi, beforeEach } from 'vitest';

const anexos = vi.hoisted(() => ({
	confirmUpload: vi.fn(),
	downloadUrl: vi.fn(),
	renameAttachment: vi.fn(),
	deleteAttachment: vi.fn()
}));
vi.mock('$lib/server/attachments', () => anexos);

import { POST, PATCH, DELETE } from './+server';

// Um evento mínimo do SvelteKit. `tipo` é o `content-type` do request — que é o que decide se o
// browser precisa de preflight, e portanto se um site de terceiro consegue disparar a chamada.
function ev(anexoId: string, opts: { tipo?: string | null; body?: unknown; acao?: string } = {}) {
	const url = new URL(`http://localhost/pacientes/p1/anexos/${anexoId}`);
	if (opts.acao) url.searchParams.set('acao', opts.acao);

	return {
		params: { id: 'p1', anexoId },
		url,
		request: {
			headers: { get: (k: string) => (k.toLowerCase() === 'content-type' ? (opts.tipo ?? null) : null) },
			json: async () => opts.body ?? {}
		}
	} as never;
}

const JSON_TIPO = 'application/json';

beforeEach(() => {
	anexos.confirmUpload.mockReset();
	anexos.downloadUrl.mockReset();
	anexos.renameAttachment.mockReset();
	anexos.deleteAttachment.mockReset();
});

// ---------------------------------------------------------------------------------------------
// A guarda cross-site. O SvelteKit só barra cross-site quando o content-type é de FORMULÁRIO
// (`is_form_content_type`), e só em produção (`if (!DEV)`) — um `POST` **sem** content-type
// escapa das duas peneiras: não é form, e é *simple request* de CORS, logo o browser nem pede
// preflight. Exigir JSON no servidor fecha isso: aí o browser é obrigado a preflightar, e o
// preflight de outra origem não é respondido.
// ---------------------------------------------------------------------------------------------
describe('guarda cross-site: os mutadores exigem content-type JSON', () => {
	it('POST sem content-type nenhum → 415, e NÃO chama o domínio', async () => {
		const res = await POST(ev('ax1', { tipo: null }));

		expect(res.status).toBe(415);
		expect(anexos.confirmUpload).not.toHaveBeenCalled();
	});

	it('POST ?acao=download sem content-type → 415, sem emitir URL nem linha de trilha', async () => {
		// O pior caso do bare POST: emitir URL assinada grava `:visualizou` na trilha LGPD. O
		// atacante não LÊ a resposta (o CORS barra a leitura), mas sujaria a auditoria.
		const res = await POST(ev('ax1', { tipo: null, acao: 'download' }));

		expect(res.status).toBe(415);
		expect(anexos.downloadUrl).not.toHaveBeenCalled();
	});

	it('POST com content-type de formulário → 415', async () => {
		// `application/x-www-form-urlencoded` é o que um <form> cross-site consegue mandar.
		const res = await POST(ev('ax1', { tipo: 'application/x-www-form-urlencoded' }));

		expect(res.status).toBe(415);
		expect(anexos.confirmUpload).not.toHaveBeenCalled();
	});

	it('DELETE sem content-type → 415, e o arquivo NÃO é apagado', async () => {
		const res = await DELETE(ev('ax1', { tipo: null }));

		expect(res.status).toBe(415);
		expect(anexos.deleteAttachment).not.toHaveBeenCalled();
	});

	it('PATCH sem content-type → 415', async () => {
		const res = await PATCH(ev('ax1', { tipo: null }));

		expect(res.status).toBe(415);
		expect(anexos.renameAttachment).not.toHaveBeenCalled();
	});

	it('com JSON (o que o app manda) passa normalmente', async () => {
		anexos.confirmUpload.mockResolvedValueOnce({ ok: true, status: 200, attachment: { id: 'ax1' } });

		const res = await POST(ev('ax1', { tipo: JSON_TIPO }));

		expect(res.status).toBe(200);
		expect(anexos.confirmUpload).toHaveBeenCalled();
	});

	it('o charset no content-type não atrapalha', async () => {
		anexos.confirmUpload.mockResolvedValueOnce({ ok: true, status: 200, attachment: { id: 'ax1' } });

		const res = await POST(ev('ax1', { tipo: 'application/json; charset=utf-8' }));

		expect(res.status).toBe(200);
	});
});

describe('POST — confirmar e baixar', () => {
	it('sem ?acao confirma o upload', async () => {
		anexos.confirmUpload.mockResolvedValueOnce({
			ok: true,
			status: 200,
			attachment: { id: 'ax1', status: 'disponivel' }
		});

		const res = await POST(ev('ax1', { tipo: JSON_TIPO }));

		expect(await res.json()).toEqual({ ok: true, attachment: { id: 'ax1', status: 'disponivel' } });
	});

	it('?acao=download devolve a URL assinada', async () => {
		anexos.downloadUrl.mockResolvedValueOnce({ ok: true, status: 200, url: 'https://bucket/x' });

		const res = await POST(ev('ax1', { tipo: JSON_TIPO, acao: 'download' }));

		expect(await res.json()).toEqual({ ok: true, url: 'https://bucket/x' });
	});

	it('erro do domínio vira o status do domínio', async () => {
		anexos.confirmUpload.mockResolvedValueOnce({ ok: false, status: 422, error: 'Não passou.' });

		const res = await POST(ev('ax1', { tipo: JSON_TIPO }));

		expect(res.status).toBe(422);
		expect(await res.json()).toEqual({ ok: false, error: 'Não passou.' });
	});
});

describe('PATCH — renomear', () => {
	it('manda o nome já sem espaço nas pontas', async () => {
		anexos.renameAttachment.mockResolvedValueOnce({ ok: true, status: 200 });

		await PATCH(ev('ax1', { tipo: JSON_TIPO, body: { nome: '  laudo.pdf  ' } }));

		expect(anexos.renameAttachment).toHaveBeenCalledWith(expect.anything(), 'ax1', 'laudo.pdf');
	});
});

describe('DELETE — remover', () => {
	it('repassa o ok', async () => {
		anexos.deleteAttachment.mockResolvedValueOnce({ ok: true, status: 204 });

		const res = await DELETE(ev('ax1', { tipo: JSON_TIPO }));

		expect(await res.json()).toEqual({ ok: true });
	});
});
