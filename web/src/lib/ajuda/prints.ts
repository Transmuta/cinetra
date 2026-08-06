// O registro das imagens da central de ajuda (doc 108 §4).
//
// O conteúdo cita uma print pelo **id**; quem resolve id → arquivo é este módulo, a partir do
// `prints.json` que `npm run prints` gera. É essa indireção que dá ao projeto uma pergunta
// respondível por teste — "que print o texto cita e não existe mais?" —, impossível quando o
// caminho da imagem está escrito no meio da prosa.

import manifesto from './prints.json';

export type PrintMeta = {
	/** Nome do arquivo dentro de `static/ajuda/`. */
	readonly arquivo: string;
	readonly largura: number;
	readonly altura: number;
};

export const PRINTS: Readonly<Record<string, PrintMeta>> = manifesto.prints;

/** Quando o manifesto foi gerado. Aparece no rodapé da central. */
export const PRINTS_GERADAS_EM: string = manifesto.gerado_em;

export const PASTA_PRINTS = '/ajuda';

/**
 * Prints que o conteúdo cita e que ainda **não** foram capturadas.
 *
 * **Vazia desde 2026-08-06** — as 73 imagens citadas existem. A lista fica porque ela é o que
 * permite ao gate ser rígido sem ser mentiroso quando um tópico novo nascer antes da foto:
 *
 *  - id citado que não está aqui nem no manifesto **reprova** o teste;
 *  - id que está aqui e **já foi gerado** também reprova — a lista tem de encolher, e não pode
 *    virar um cemitério que ninguém revisita;
 *  - id aqui que nenhum tópico cita também reprova.
 *
 * Na tela, o lugar de uma print pendente vira a nota "em preparo" (ver `Print.svelte`): quem lê
 * sabe que falta a foto, em vez de achar que a página quebrou.
 */
export const PENDENTES: readonly string[] = [];

export function print(id: string): PrintMeta | undefined {
	return PRINTS[id];
}

export function caminhoDaPrint(id: string): string | undefined {
	const meta = PRINTS[id];
	return meta && `${PASTA_PRINTS}/${meta.arquivo}`;
}
