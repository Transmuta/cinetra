import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { startUpload } from '$lib/server/attachments';
import { exigirJson } from '$lib/server/csrf';

// Passo 1 do upload (doc 51): pede à API a linha `pendente` e a URL de `PUT` assinada.
//
// O `patient_id` sai do **path**, nunca do corpo — mesma regra da criação de série. E o que volta
// para o browser é um ticket de escrita para UMA chave, com tipo e tamanho já dentro da
// assinatura: não é uma credencial do bucket, e não serve para mais nada.
//
// `exigirJson` é a guarda cross-site — ver o moduledoc de `$lib/server/csrf`.
export const POST: RequestHandler = async (event) => {
	const barrado = exigirJson(event);
	if (barrado) return barrado;

	const body = (await event.request.json().catch(() => ({}))) as {
		nome?: string;
		content_type?: string;
		bytes?: number;
	};

	const r = await startUpload(event, event.params.id, {
		nome: String(body.nome ?? ''),
		content_type: String(body.content_type ?? ''),
		bytes: Number(body.bytes ?? 0)
	});

	if (r.ok) return json({ ok: true, attachment: r.attachment, upload: r.upload }, { status: 201 });
	return json({ ok: false, error: r.error }, { status: r.status || 500 });
};
