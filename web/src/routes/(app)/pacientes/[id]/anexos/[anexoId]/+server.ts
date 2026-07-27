import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { confirmUpload, downloadUrl, renameAttachment, deleteAttachment } from '$lib/server/attachments';
import { exigirJson } from '$lib/server/csrf';

// Os três verbos sobre um anexo já existente (doc 51).
//
// `POST` faz dois papéis distintos, decididos por `?acao=`: confirmar o upload e emitir a URL de
// leitura. As duas são **efeitos**, não leituras idempotentes — a segunda grava a linha de trilha
// LGPD (`:visualizou`), então um `GET` daria a impressão errada de ser gratuita, e um prefetch do
// browser poluiria a auditoria com acessos que ninguém pediu.
//
// Os três exigem `content-type: application/json` (`exigirJson`): sem isso um `POST` cru de outra
// origem atravessa a proteção CSRF do SvelteKit **e** o preflight de CORS. Ver o moduledoc de
// `$lib/server/csrf`.

export const POST: RequestHandler = async (event) => {
	const barrado = exigirJson(event);
	if (barrado) return barrado;

	const acao = event.url.searchParams.get('acao');

	if (acao === 'download') {
		const r = await downloadUrl(event, event.params.anexoId);
		if (r.ok) return json({ ok: true, url: r.url });
		return json({ ok: false, error: r.error }, { status: r.status || 500 });
	}

	const r = await confirmUpload(event, event.params.anexoId);
	if (r.ok) return json({ ok: true, attachment: r.attachment });
	return json({ ok: false, error: r.error }, { status: r.status || 500 });
};

export const PATCH: RequestHandler = async (event) => {
	const barrado = exigirJson(event);
	if (barrado) return barrado;

	const body = (await event.request.json().catch(() => ({}))) as { nome?: string };

	const r = await renameAttachment(event, event.params.anexoId, String(body.nome ?? '').trim());
	if (r.ok) return json({ ok: true });
	return json({ ok: false, error: r.error }, { status: r.status || 500 });
};

export const DELETE: RequestHandler = async (event) => {
	const barrado = exigirJson(event);
	if (barrado) return barrado;

	const r = await deleteAttachment(event, event.params.anexoId);
	if (r.ok) return json({ ok: true });
	return json({ ok: false, error: r.error }, { status: r.status || 500 });
};
