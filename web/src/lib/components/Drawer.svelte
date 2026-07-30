<script lang="ts">
	// Shell de drawer: o par lateral do Modal.svelte. Painel ancorado à direita sobre um
	// overlay rgba(8,10,12,.42) que fecha no clique-fora e no Esc — sem o overlay o painel
	// flutuava sobre a tela ainda clicável, e um clique atrás dele ia para a grade em vez
	// de fechar o painel.
	//
	// Estrutura fiel ao Modal: cabeçalho com o X à direita (o `header` traz só o conteúdo à
	// esquerda dele), corpo que rola sozinho e rodapé opcional.
	import type { Snippet } from 'svelte';
	import X from '@lucide/svelte/icons/x';
	import { aprisionarTab } from '$lib/dialogo';

	let {
		label,
		onClose,
		width = 'w-[404px]',
		header = undefined,
		children,
		footer = undefined
	}: {
		/** rótulo acessível do painel (não é exibido; o título visível vai no `header`) */
		label: string;
		onClose: () => void;
		/** classe w-* — a largura do painel (404px no drawer do agendamento) */
		width?: string;
		/** conteúdo do cabeçalho à esquerda do X (chips de status, título…) */
		header?: Snippet;
		children: Snippet;
		footer?: Snippet;
	} = $props();

	// Um modal aberto POR CIMA do drawer (remarcar, confirmar cancelamento) fica com o Esc:
	// os dois escutam a janela, e sem esta guarda uma tecla fecharia os dois de uma vez.
	function aoTeclar(event: KeyboardEvent) {
		if (event.key !== 'Escape') return;
		if (document.querySelector('[data-modal]')) return;
		onClose();
	}

	// AN-08 (WCAG 2.4.3): abrir move o foco para o painel; fechar devolve a quem abriu — o
	// mesmo desenho do Modal, e pelo mesmo motivo (Tab passeava pela tela de trás).
	let painel = $state<HTMLElement>();

	$effect(() => {
		const antes = document.activeElement as HTMLElement | null;
		painel?.focus();
		return () => antes?.focus?.();
	});
</script>

<svelte:window onkeydown={aoTeclar} />

<div
	class="fixed inset-0 z-40 bg-[rgba(8,10,12,0.42)]"
	role="presentation"
	onclick={(e) => e.target === e.currentTarget && onClose()}
>
	<!-- `div` e não `aside`: com `role="dialog"` o elemento já é o painel modal, e um landmark
	     complementar com papel interativo é justamente o que o a11y do Svelte recusa. -->
	<div
		bind:this={painel}
		tabindex="-1"
		class="absolute inset-y-0 right-0 flex {width} max-w-full flex-col border-l border-edge bg-surface shadow-modal focus:outline-none"
		role="dialog"
		aria-modal="true"
		aria-label={label}
		onkeydown={(e) => aprisionarTab(e, painel)}
	>
		<div class="flex items-center gap-2 border-b border-edge px-4 py-3.5">
			{#if header}{@render header()}{/if}
			<button
				type="button"
				onclick={onClose}
				aria-label="Fechar"
				class="ml-auto grid size-7.5 shrink-0 place-items-center rounded-md text-muted hover:bg-surface-2"
			>
				<X size={17} />
			</button>
		</div>

		<div class="min-h-0 flex-1 overflow-auto px-4 py-4">{@render children()}</div>

		{#if footer}
			<div class="border-t border-edge px-4 py-3">{@render footer()}</div>
		{/if}
	</div>
</div>
