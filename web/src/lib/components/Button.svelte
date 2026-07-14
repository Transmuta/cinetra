<script lang="ts">
	import type { Snippet } from 'svelte';

	let {
		variant = 'primary',
		type = 'button',
		href = undefined,
		reload = false,
		loading = false,
		disabled = false,
		onclick = undefined,
		children
	}: {
		variant?: 'primary' | 'ghost';
		type?: 'button' | 'submit';
		href?: string;
		// Força navegação completa do browser (data-sveltekit-reload) em vez de roteamento
		// client-side. Necessário para links a endpoints `+server` (ex.: /auth/google), que
		// não têm `+page` e 404am se o client router tentar resolvê-los como página.
		reload?: boolean;
		// Carregando: sinaliza aria-busy e trava o clique. Num link de navegação completa
		// (ex.: Google), evita o duplo-clique enquanto o browser sai da página.
		loading?: boolean;
		disabled?: boolean;
		onclick?: (event: MouseEvent) => void;
		children: Snippet;
	} = $props();

	// Botão primário do protótipo (:3484): quase-preto no claro / quase-branco no escuro.
	const base =
		'flex w-full items-center justify-center gap-2 rounded-md px-4 py-[11px] text-[14px] font-bold transition-colors disabled:cursor-not-allowed disabled:opacity-60';
	const variants = {
		primary: 'bg-primary text-on-primary hover:bg-primary-hover',
		ghost: 'border border-edge-strong bg-surface text-ink hover:bg-surface-2'
	} as const;
</script>

{#if href}
	<a
		{href}
		{onclick}
		data-sveltekit-reload={reload ? '' : undefined}
		aria-busy={loading ? 'true' : undefined}
		class="{base} {variants[variant]} {loading ? 'pointer-events-none opacity-70' : ''}"
		>{@render children()}</a
	>
{:else}
	<button {type} {onclick} disabled={disabled || loading} class="{base} {variants[variant]}"
		>{@render children()}</button
	>
{/if}
