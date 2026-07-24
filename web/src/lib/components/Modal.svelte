<script lang="ts">
	// Shell de modal fiel ao modalShell do protótipo (:1898): overlay rgba(8,10,12,.42)
	// que fecha no clique-fora e no Esc; painel de raio 12px com sombra profunda e SEM
	// borda; header 15px/18px com título 15.5px/700 + X (iconBtn de 30px); corpo com
	// padding 18px que rola sozinho; rodapé opcional 13px/18px com ações à direita.
	import type { Snippet } from 'svelte';
	import X from '@lucide/svelte/icons/x';

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
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && onClose()} />

<div
	data-modal
	class="fixed inset-0 z-50 grid place-items-center bg-[rgba(8,10,12,0.42)] p-5"
	role="presentation"
	onclick={(e) => e.target === e.currentTarget && onClose()}
>
	<div
		class="flex max-h-[90dvh] w-full {maxWidth} animate-scale flex-col overflow-hidden rounded-[12px] bg-surface shadow-modal"
		role="dialog"
		aria-modal="true"
		aria-label={title}
	>
		<div class="flex items-center gap-2 border-b border-edge px-4.5 py-3.75">
			<h2 class="min-w-0 flex-1 truncate text-[15.5px] font-bold">{title}</h2>
			<button
				type="button"
				onclick={onClose}
				aria-label="Fechar"
				class="grid size-7.5 shrink-0 place-items-center rounded-[7px] border border-edge bg-surface text-muted hover:bg-surface-2"
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
