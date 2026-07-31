// Toast global no molde do protótipo (interface/Movimento.dc.html — toast() :1030):
// UMA mensagem por vez, sem fila; um toast novo substitui o atual e reinicia o relógio.
// A casca visual é o componente Toast.svelte, montado no layout do shell.
//
// Diferença do protótipo: ele usava o MESMO visual até para aviso negativo (:538), o que fazia
// um erro ("Dados inválidos") aparecer com o check verde de sucesso. Aqui o toast carrega uma
// `variant` para que erro e sucesso sejam visualmente distintos.

/** 2800ms, verbatim do protótipo. */
export const TOAST_DURATION_MS = 2800;

/** `success` = confirmação (check no acento); `error` = falha (ícone de alerta danger). */
export type ToastVariant = 'success' | 'error';

export interface ActiveToast {
	message: string;
	variant: ToastVariant;
}

let active = $state<ActiveToast | null>(null);
let timer: ReturnType<typeof setTimeout> | undefined;

/** Mostra um toast (substitui o atual, se houver). `variant` default = `success`. */
export function toast(message: string, variant: ToastVariant = 'success'): void {
	active = { message, variant };
	clearTimeout(timer);
	timer = setTimeout(() => (active = null), TOAST_DURATION_MS);
}

/** Esconde imediatamente. */
export function dismissToast(): void {
	clearTimeout(timer);
	timer = undefined;
	active = null;
}

/** Leitura reativa do toast atual (null = nada na tela). */
export function currentToast(): ActiveToast | null {
	return active;
}
