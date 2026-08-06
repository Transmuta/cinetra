import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { fetchCandidates } from '$lib/server/waitlist';
import type { CandidatesResponse } from '$lib/waitlist';

// O "quem cabe aqui?" (AN-12, doc 64): a vaga que abriu (cancelamento/falta) pergunta à fila
// quem casa com aquele horário. Buscado pelo drawer **quando ele abre** num bloco de vaga —
// mesma razão de `/agenda/mensagens/[id]` para não ir no load: um dia cheio tem dezenas de
// blocos e o drawer mostra um.
//
// Degrada para a lista vazia em tudo (slot incompleto, API fora): a seção fica vazia; o drawer
// nunca deixa de abrir por causa da fila. O bloco é o assunto da tela; isto é um anexo dele.
export const GET: RequestHandler = async (event) => {
	const professional_id = event.url.searchParams.get('professional_id') ?? '';
	const starts_at = event.url.searchParams.get('starts_at') ?? '';
	const ends_at = event.url.searchParams.get('ends_at') ?? '';

	if (!professional_id || !starts_at || !ends_at) return json({ candidates: [] } satisfies CandidatesResponse);

	const r = await fetchCandidates(event, { professional_id, starts_at, ends_at });
	return json({ candidates: r.data?.candidates ?? [] } satisfies CandidatesResponse);
};
