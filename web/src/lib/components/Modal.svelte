<script lang="ts">
	// Shell de modal fiel ao modalShell do protótipo (:1898): overlay rgba(8,10,12,.42)
	// que fecha no clique-fora e no Esc; painel de raio 12px com sombra profunda e SEM
	// borda; header 15px/18px com título 15.5px/700 + X (iconBtn de 30px); corpo com
	// padding 18px que rola sozinho; rodapé opcional 13px/18px com ações à direita.
	import type { Snippet } from 'svelte';
	import X from '@lucide/svelte/icons/x';
	import { aprisionarTab } from '$lib/dialogo';

	let {
		title,
		onClose,
		maxWidth = 'max-w-[440px]',
		children,
		footer = undefined
	}: {
		title: string;
		onClose: () => void;
		/** classe max-w-* — a largura que o modalShell do protótipo recebia por chamada (440–560px) */
		maxWidth?: string;
		children: Snippet;
		footer?: Snippet;
	} = $props();

	// AN-08 (WCAG 2.4.3): abrir move o foco para o diálogo; fechar DEVOLVE ao gatilho. Sem isto,
	// o teclado continuava na tela de trás — Tab passeava por baixo do overlay e o leitor de tela
	// nem sabia que um diálogo abriu. O `tabindex="-1"` torna o painel focável sem entrar na
	// ordem do Tab.
	let painel = $state<HTMLElement>();

	$effect(() => {
		const antes = document.activeElement as HTMLElement | null;
		painel?.focus();
		return () => antes?.focus?.();
	});
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && onClose()} />

<div
	data-modal
	class="fixed inset-0 z-painel grid place-items-center bg-overlay p-5"
	role="presentation"
	onclick={(e) => e.target === e.currentTarget && onClose()}
>
	<div
		bind:this={painel}
		tabindex="-1"
		class="flex max-h-[90dvh] w-full {maxWidth} animate-scale flex-col overflow-hidden rounded-cartao bg-surface shadow-modal focus:outline-none"
		role="dialog"
		aria-modal="true"
		aria-label={title}
		onkeydown={(e) => aprisionarTab(e, painel)}
	>
		<div class="flex items-center gap-2 border-b border-edge px-4.5 py-3.75">
			<h2 class="min-w-0 flex-1 truncate text-titulo font-bold">{title}</h2>
			<button
				type="button"
				onclick={onClose}
				aria-label="Fechar"
				class="grid size-7.5 shrink-0 place-items-center rounded-controle border border-edge bg-surface text-muted hover:bg-surface-2"
			>
				<X size={16} />
			</button>
		</div>

		<div class="min-h-0 flex-1 overflow-y-auto p-4.5">{@render children()}</div>

		{#if footer}
			<div class="flex justify-end gap-2.25 border-t border-edge px-4.5 py-3.25">
				{@render footer()}
			</div>
		{/if}
	</div>
</div>
