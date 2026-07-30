/**
 * Aprisionamento de foco (focus trap) dos shells de diálogo — `Modal` e `Drawer`.
 *
 * O AN-08 (doc 80) fez o passo 1 de 2: abrir move o foco para o painel e fechar devolve ao
 * gatilho. Faltava o passo 2, e ele foi **medido** no doc 83 (ACC-07): com o drawer aberto, o
 * **7º Tab** levava o foco para o `body` — a tela de trás do overlay, que o `aria-modal` esconde
 * do leitor de tela mas não do Tab. Quem navega por teclado saía do diálogo sem perceber e
 * continuava tabulando por uma tela que não podia usar.
 *
 * Mora aqui, e não em cada componente, porque os dois shells precisam do MESMO comportamento —
 * e porque todo modal, drawer e confirmação do app herda deles (o `ConfirmDialog` é um `Modal`).
 */

/**
 * Um elemento escondido não recebe Tab, e a borda do trap tem de concordar com isso: apontar
 * `focus()` para um `display:none` não move o foco, e o ciclo quebra em silêncio.
 *
 * `checkVisibility()` é a pergunta certa — considera os ANCESTRAIS, então pega o caso real (uma
 * seção inteira escondida por classe). Ela não existe no jsdom, e lá também não há CSS aplicado:
 * a retaguarda é o `getComputedStyle`, que o jsdom implementa e que cobre o estilo inline.
 *
 * Medido antes de escolher: no jsdom `offsetWidth` é **sempre 0** e `getClientRects()` vem vazio,
 * então filtrar por caixa renderizada — o jeito "óbvio" — zera a lista inteira dentro do teste e
 * o trap passa a mandar o foco para o painel, com a suíte concordando.
 */
function visivel(el: HTMLElement): boolean {
	if (typeof el.checkVisibility === 'function') return el.checkVisibility();
	const estilo = getComputedStyle(el);
	return estilo.display !== 'none' && estilo.visibility !== 'hidden';
}

/** Os elementos que o Tab alcança dentro de `raiz`, na ordem do documento. */
export function focaveis(raiz: HTMLElement): HTMLElement[] {
	const seletor = [
		'a[href]',
		'button:not([disabled])',
		'input:not([disabled]):not([type="hidden"])',
		'select:not([disabled])',
		'textarea:not([disabled])',
		'[tabindex]:not([tabindex="-1"])'
	].join(',');

	return [...raiz.querySelectorAll<HTMLElement>(seletor)].filter(visivel);
}

/**
 * Faz o Tab circular dentro do painel: do último volta ao primeiro, e Shift+Tab do primeiro
 * (ou do próprio painel) vai ao último.
 *
 * Pendurado no `keydown` do painel, então pega o Tab de qualquer descendente pela subida do
 * evento. Diálogo sem nada focável dentro devolve o foco ao painel — nunca ao fundo.
 */
export function aprisionarTab(event: KeyboardEvent, painel: HTMLElement | undefined): void {
	if (event.key !== 'Tab' || !painel) return;

	const alvos = focaveis(painel);
	if (!alvos.length) {
		event.preventDefault();
		painel.focus();
		return;
	}

	const primeiro = alvos[0];
	const ultimo = alvos[alvos.length - 1];
	const ativo = document.activeElement;

	// Para trás a partir da borda de cima — o painel conta como borda porque é ele que recebe o
	// foco ao abrir (`tabindex="-1"`), e Shift+Tab dali cairia no fundo.
	if (event.shiftKey && (ativo === primeiro || ativo === painel)) {
		event.preventDefault();
		ultimo.focus();
		return;
	}

	if (!event.shiftKey && ativo === ultimo) {
		event.preventDefault();
		primeiro.focus();
	}
}
