// Paginação de lista — o pouco que toda tela paginada repete.
//
// Nasceu dentro de `$lib/patients` (a primeira lista a paginar) e saiu quando a **fila de
// espera** passou a paginar também (F6). São três coisas genéricas — a forma do recorte que a
// API devolve, ler `?page=` da URL e escrever o rótulo do rodapé — e nenhuma delas tem qualquer
// relação com paciente. `$lib/patients` continua reexportando os nomes, então nada que já os
// importava de lá precisou mudar.

/**
 * Recorte de página devolvido pela API (`page` no corpo do GET).
 *
 * `total` é **opcional** desde a caixa de notificações (#54): contá-lo obriga a API a ler o
 * recorte inteiro (`COUNT(*) OVER ()`), medido em 10.265 buffers contra 26 com `LIMIT` puro. As
 * telas que exibem "X–Y de Z" pagam esse preço porque mostram o Z; a caixa do sino só precisa de
 * "tem mais?" e não paga. `pageLabel` já devolve vazio quando não há total.
 */
export interface PageInfo {
	limit: number;
	offset: number;
	total?: number;
	more: boolean;
}

/**
 * Lê `?page=` da URL. Qualquer coisa que não seja inteiro ≥ 1 vira 1 — página inválida na URL
 * não é erro do usuário a ponto de quebrar a tela; é só "começa do começo".
 */
export function parsePage(value: string | null | undefined): number {
	const n = Number(value);
	return Number.isInteger(n) && n > 0 ? n : 1;
}

/** Rótulo do rodapé da lista ("1–50 de 214"). Vazio quando não há resultado. */
export function pageLabel(page: PageInfo, shown: number): string {
	if (!page.total || !shown) return '';
	return `${page.offset + 1}–${page.offset + shown} de ${page.total}`;
}
