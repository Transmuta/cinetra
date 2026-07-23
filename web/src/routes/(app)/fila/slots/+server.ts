import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { fetchAllSlots } from '$lib/server/waitlist';
import { PAGE_SIZE } from '$lib/waitlist';

// As vagas de TODA a fila numa passada (`GET /api/waitlist/slots`, o motor em lote). A lista o
// consome por `fetch` DEPOIS de renderizar, para pintar o estado "tem vaga" em cada linha sem
// bloquear o load nem fazer N chamadas ao motor (o endpoint por-item `/fila/[id]/slots` seria o
// N+1 que o comentário daquele arquivo evita). A falha degrada para `{}` — as linhas ficam sem a
// vaga, não numa tela de erro (mesmo desenho do modal de Oferecer).
// A janela (`?limit=&offset=`) vem da própria tela e é repassada: com a fila paginada (F6), o
// motor só precisa calcular vaga para quem está na página desenhada.
export const GET: RequestHandler = async (event) => {
	const r = await fetchAllSlots(event, {
		limit: Number(event.url.searchParams.get('limit')) || PAGE_SIZE,
		offset: Number(event.url.searchParams.get('offset')) || 0
	});

	return json({ slots_by_entry: r.data?.slots_by_entry ?? {} });
};
