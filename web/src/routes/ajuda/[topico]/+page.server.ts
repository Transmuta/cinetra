import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { canonical } from '$lib/seo';
import { topicoPorId, vizinhos, SECAO_POR_ID, NOME_DO_PAPEL } from '$lib/ajuda';

// O tópico é resolvido no SERVIDOR, e um id desconhecido vira 404 de verdade.
//
// Resolver no cliente daria uma página que responde 200 com "não encontrado" no corpo — o que
// mantém link morto indexado e faz o buscador servir a página vazia para sempre. A central existe
// para ser encontrada; então o 404 dela precisa ser um 404.
export const load: PageServerLoad = ({ params, url }) => {
	const topico = topicoPorId(params.topico);
	if (!topico) error(404, 'Este tópico de ajuda não existe.');

	return {
		topico,
		secao: SECAO_POR_ID[topico.secao],
		papeis: topico.papeis.map((p) => NOME_DO_PAPEL[p]),
		...vizinhos(topico.id),
		canonical: canonical(url),
		origem: url.origin
	};
};
