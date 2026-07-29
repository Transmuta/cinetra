<script lang="ts">
	// O botão de ação com o estado "está indo" embutido (ver `$lib/forms.svelte.ts`).
	//
	// Não impõe visual: a classe do chamador passa inteira. O que ele centraliza são as três
	// coisas que estavam faltando ou saindo diferentes em cada tela — travar durante o envio,
	// anunciar isso a leitor de tela (`aria-busy`) e MOSTRAR o giro, porque um botão só apagado
	// parece quebrado e convida ao segundo clique.
	import type { Snippet } from 'svelte';
	import Loader from '@lucide/svelte/icons/loader-circle';

	let {
		emVoo = false,
		disabled = false,
		type = 'submit',
		form = undefined,
		title = undefined,
		ariaLabel = undefined,
		name = undefined,
		value = undefined,
		/** Botão só de ícone: o giro ENTRA NO LUGAR do conteúdo, em vez de somar a ele. */
		trocaConteudo = false,
		size = 14,
		class: classe = '',
		onclick = undefined,
		children
	}: {
		emVoo?: boolean;
		disabled?: boolean;
		type?: 'submit' | 'button';
		form?: string;
		title?: string;
		ariaLabel?: string;
		name?: string;
		value?: string;
		trocaConteudo?: boolean;
		size?: number;
		class?: string;
		onclick?: () => void;
		children: Snippet;
	} = $props();
</script>

<button
	{type}
	{form}
	{title}
	{name}
	{value}
	{onclick}
	aria-label={ariaLabel}
	aria-busy={emVoo}
	disabled={disabled || emVoo}
	class={classe}
>
	{#if emVoo}<Loader {size} class="animate-spin" />{/if}
	{#if !(emVoo && trocaConteudo)}{@render children()}{/if}
</button>
