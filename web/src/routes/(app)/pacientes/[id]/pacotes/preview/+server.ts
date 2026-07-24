import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { previewSeries, type SeriesInput } from '$lib/server/packages';

// A prévia da série (o save-gate), consumida pelo modal de criação por `fetch` a cada ajuste da
// grade. O `patient_id` NÃO vem do corpo — sai do path (`[id]`), como no `index`: um corpo forjado
// não cria pacote em outro paciente. A falha degrada para `null` — o modal mostra o aviso genérico
// e não desenha a grade fantasma (mesmo desenho do `/fila/slots`).
export const POST: RequestHandler = async (event) => {
	const body = (await event.request.json().catch(() => ({}))) as Partial<SeriesInput>;
	const input = { ...body, patient_id: event.params.id } as SeriesInput;

	const r = await previewSeries(event, input);
	return json({ preview: r.preview }, { status: r.status || 200 });
};
