import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { fetchAllSlots } from '$lib/server/waitlist';
import { PAGE_SIZE, type SlotsByEntryResponse } from '$lib/waitlist';

// As vagas de TODA a fila numa passada (`GET /api/waitlist/slots`, o motor em lote). A lista o
// consome por `fetch` DEPOIS de renderizar, para pintar o estado "tem vaga" em cada linha sem
// bloquear o load nem fazer N chamadas ao motor (o endpoint por-item `/fila/[id]/slots` seria o
// N+1 que o comentário daquele arquivo evita). A falha degrada para `{}` — as linhas ficam sem a
// vaga, não numa tela de erro (mesmo desenho do modal de Oferecer).
// A janela vem da própria tela e é repassada inteira: `limit`/`offset` **e o filtro**. O filtro
// faz parte da janela — sem ele, a fila mostra os itens de um recorte e o motor calcula as vagas
// de outro, e a linha filtrada aparece sem chip (bate-volta: a tela mostrava `…76e27f` enquanto
// o motor calculava `…1979b9`).
export const GET: RequestHandler = async (event) => {
	const prio = event.url.searchParams.get('prio');

	const r = await fetchAllSlots(event, {
		limit: Number(event.url.searchParams.get('limit')) || PAGE_SIZE,
		offset: Number(event.url.searchParams.get('offset')) || 0,
		...(prio ? { prio } : {})
	});

	return json({ slots_by_entry: r.data?.slots_by_entry ?? {} } satisfies SlotsByEntryResponse);
};
