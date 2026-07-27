import { goto } from '$app/navigation';

/**
 * O estado das listas mora na **URL** (`?q=`, `?filter=`, `?page=`), e não em variável de
 * componente: é o que faz o botão voltar, o F5 e o link colado funcionarem — e é o que permite o
 * `+page.server.ts` buscar já filtrado no servidor, em vez de mandar a lista inteira ao browser.
 *
 * Quatro telas escreveram a mesma função `navigate(patch)` para isso (Pacientes, Fila, Auditoria
 * e Notificações). Este módulo é ela, uma vez — o **I68** do doc 35, que nasceu de o rodapé de
 * paginação da Auditoria ter ficado **sem `replaceState`**: cada clique em "próxima" empilhava uma
 * entrada no histórico, então sair da tela pedia tantos "voltar" quantas páginas a pessoa tivesse
 * folheado. Paginar é *refinar a mesma tela*, não navegar para outra.
 */

/** O patch a aplicar na query string. `null` (ou `''`) **remove** a chave. */
export type QueryPatch = Record<string, string | null>;

/** A query string resultante de aplicar `patch` sobre `params`. Sem o `?`. */
export function patchQuery(params: URLSearchParams, patch: QueryPatch): string {
	const next = new URLSearchParams(params);
	for (const [key, value] of Object.entries(patch)) {
		if (value === null || value === '') next.delete(key);
		else next.set(key, value);
	}
	return next.toString();
}

/** A URL completa: base + query, sem deixar um `?` órfão quando a query fica vazia. */
export function hrefWithQuery(base: string, params: URLSearchParams, patch: QueryPatch): string {
	const qs = patchQuery(params, patch);
	return qs ? `${base}?${qs}` : base;
}

/**
 * Navega para a mesma tela com a query string remendada.
 *
 * As três opções são o contrato desta navegação, e cada uma tem motivo:
 *
 *   * `keepFocus` — quem está digitando na busca não perde o cursor a cada tecla;
 *   * `noScroll` — refinar um filtro não joga a pessoa para o topo da lista;
 *   * `replaceState` — **paginar e filtrar não empilham histórico** (I68).
 */
export function navigateQuery(
	base: string,
	params: URLSearchParams,
	patch: QueryPatch
): Promise<void> {
	return goto(hrefWithQuery(base, params, patch), {
		keepFocus: true,
		noScroll: true,
		replaceState: true
	});
}
