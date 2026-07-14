// Toast global no molde do protótipo (interface/Movimento.dc.html — toast() :1030):
// UMA mensagem por vez, sem fila e sem variantes (até aviso negativo usa o mesmo
// visual lá, :538); um toast novo substitui o atual e reinicia o relógio.
// A casca visual é o componente Toast.svelte, montado no layout do shell.

/** 2800ms, verbatim do protótipo. */
export const TOAST_DURATION_MS = 2800;

let message = $state<string | null>(null);
let timer: ReturnType<typeof setTimeout> | undefined;

/** Mostra um toast (substitui o atual, se houver). */
export function toast(msg: string): void {
	message = msg;
	clearTimeout(timer);
	timer = setTimeout(() => (message = null), TOAST_DURATION_MS);
}

/** Esconde imediatamente. */
export function dismissToast(): void {
	clearTimeout(timer);
	timer = undefined;
	message = null;
}

/** Leitura reativa da mensagem atual (null = nada na tela). */
export function currentToast(): string | null {
	return message;
}
