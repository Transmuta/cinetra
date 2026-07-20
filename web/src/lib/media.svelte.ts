// Media query como estado reativo (runes). Existe porque a agenda tem uma diferença de
// COMPORTAMENTO no mobile, não só de layout: abaixo de 860px o grid mostra **um profissional
// por vez** (protótipo `renderAgendaMobile` :1703), e isso não se resolve com classe do
// Tailwind — é outra árvore de componentes, decidida em JS.
//
// Fora do browser (SSR) devolve `false`: o servidor não tem viewport, e o primeiro render tem
// de ser o do desktop para não piscar a versão errada em quem está no desktop.
import { onDestroy } from 'svelte';

export function mediaQuery(query: string): { current: boolean } {
	let matches = $state(false);

	if (typeof window !== 'undefined' && typeof window.matchMedia === 'function') {
		const mql = window.matchMedia(query);
		matches = mql.matches;

		const onChange = (e: MediaQueryListEvent) => (matches = e.matches);
		mql.addEventListener('change', onChange);
		onDestroy(() => mql.removeEventListener('change', onChange));
	}

	return {
		get current() {
			return matches;
		}
	};
}

/** O breakpoint do protótipo (:1556): abaixo disso, a visão Dia troca de render. */
export const AGENDA_MOBILE = '(max-width: 859px)';
