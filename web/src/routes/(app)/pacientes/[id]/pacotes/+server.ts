import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { createSeries, type SeriesInput } from '$lib/server/packages';
import { exigirJson } from '$lib/server/csrf';

// Cria a série, chamado pelo modal por `fetch`. Como na prévia, o `patient_id` sai do path, nunca
// do corpo. Repassa os três desfechos do save-gate para a tela decidir:
//   * 201  → { ok, package }        — criado; o modal fecha e a ficha recarrega.
//   * 422  → { blocked }            — o mundo recusou (fora do expediente, ou conflito sem `forcar`);
//                                     o modal reapresenta a prévia com o "agendar mesmo assim".
//   * erro → { error }              — falha genérica; o modal mostra a mensagem.
//
// `exigirJson` é a guarda cross-site — ver o moduledoc de `$lib/server/csrf`. Faltava aqui (doc
// 101, M11): `request.json()` ignora o content-type, então um `POST` **sem** content-type nenhum
// atravessava as duas peneiras do Kit e criava a série. Os endpoints de anexo já guardavam.
export const POST: RequestHandler = async (event) => {
	const barrado = exigirJson(event);
	if (barrado) return barrado;

	const body = (await event.request.json().catch(() => ({}))) as Partial<SeriesInput>;
	const input = { ...body, patient_id: event.params.id } as SeriesInput;

	const r = await createSeries(event, input);

	if (r.ok) return json({ ok: true, package: r.package }, { status: 201 });
	if (r.blocked) return json({ ok: false, blocked: r.blocked }, { status: 422 });
	return json({ ok: false, error: r.error }, { status: r.status || 500 });
};
