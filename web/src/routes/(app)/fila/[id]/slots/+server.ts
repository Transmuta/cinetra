import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { fetchSlots } from '$lib/server/waitlist';
import type { SlotsResponse } from '$lib/waitlist';

// As vagas compatíveis de UM item da fila (`GET /api/waitlist/:id/slots`, o motor `find_slots`).
// Endpoint próprio consumido por `fetch` do modal de Oferecer — NÃO no load da lista, que faria N
// chamadas ao motor (uma por item), o mesmo N+1 que a agenda evitou no expediente.
//
// `+server` chamado por `fetch` do cliente, não por `<a>`: o gotcha do `data-sveltekit-reload`
// não se aplica. A falha degrada para `slots: []` — o modal mostra o vazio ("nenhuma vaga"), não
// uma tela de erro.
export const GET: RequestHandler = async (event) => {
	const r = await fetchSlots(event, event.params.id);
	return json({ slots: r.data?.slots ?? [] } satisfies SlotsResponse);
};
