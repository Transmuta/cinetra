import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { fetchMessages } from '$lib/server/messages';

// A timeline de comunicação de um agendamento (doc 52 §6), buscada pelo drawer **quando ele
// abre**.
//
// Sob demanda, e não no load da agenda, por uma razão de volume: um dia cheio tem dezenas de
// blocos e o drawer mostra um de cada vez. Carregar a comunicação de todos para exibir a de um
// multiplicaria o payload da tela mais usada do sistema pelo número de participantes — e o doc
// 25 §10 já cortou o Mês por esse mesmo motivo.
//
// É um `+server` consumido por `fetch` do cliente, não por `<a>`: o gotcha do
// `data-sveltekit-reload` não se aplica.
export const GET: RequestHandler = async (event) => {
	const { status, data } = await fetchMessages(event, event.params.id);

	// Sem dado, devolve a forma vazia em vez de propagar o erro: o drawer precisa abrir mesmo
	// quando a comunicação está fora do ar. O bloco é o assunto da tela; isto é o rodapé dele.
	return json(data ?? { participantes: [] }, { status: data ? 200 : status || 502 });
};
