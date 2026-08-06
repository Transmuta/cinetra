import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { previewSeries, type SeriesInput } from '$lib/server/packages';
import type { PackagePreviewResponse } from '$lib/packages';
import { exigirJson } from '$lib/server/csrf';

// A prévia da série (o save-gate), consumida pelo modal de criação por `fetch` a cada ajuste da
// grade. O `patient_id` NÃO vem do corpo — sai do path (`[id]`), como no `index`: um corpo forjado
// não cria pacote em outro paciente. A falha degrada para `null` — o modal mostra o aviso genérico
// e não desenha a grade fantasma (mesmo desenho do `/fila/slots`).
//
// `exigirJson` pela mesma razão do `index` (doc 101, M11): a prévia não escreve, mas ela **lê a
// agenda** de um paciente pelo path, e a regra do projeto é uma só para todo `+server.ts` que
// aceita `POST` — depender de "este aqui não muda estado" é como a exceção começa.
export const POST: RequestHandler = async (event) => {
	const barrado = exigirJson(event);
	if (barrado) return barrado;

	const body = (await event.request.json().catch(() => ({}))) as Partial<SeriesInput>;
	const input = { ...body, patient_id: event.params.id } as SeriesInput;

	const r = await previewSeries(event, input);
	return json({ preview: r.preview } satisfies PackagePreviewResponse, {
		status: r.status || 200
	});
};
