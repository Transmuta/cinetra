<script lang="ts">
	import { Sun, Moon } from '@lucide/svelte';

	// `variant`: 'default' = botão claro (topbar/telas de auth); 'rail' = estilo do rail escuro
	// (transparente, ícone branco/60), para conviver com os outros ícones da barra.
	let { initial = null, variant = 'default' }: {
		initial?: string | null;
		variant?: 'default' | 'rail';
	} = $props();

	// Estado do tema. Sem cookie, deriva do atributo estampado no SSR ou do SO.
	let dark = $state(resolveInitial());

	const cls = $derived(
		variant === 'rail'
			? 'grid size-10 place-items-center rounded-controle text-white/60 transition-colors hover:bg-rail-item/60 hover:text-white'
			: 'grid size-9 place-items-center rounded-controle border border-edge bg-surface text-muted hover:bg-surface-2'
	);
	const iconSize = $derived(variant === 'rail' ? 18 : 16);

	function resolveInitial(): boolean {
		if (initial) return initial === 'dark';
		if (typeof document !== 'undefined') {
			const attr = document.documentElement.getAttribute('data-theme');
			if (attr) return attr === 'dark';
			return window.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false;
		}
		return false;
	}

	function toggle() {
		dark = !dark;
		const theme = dark ? 'dark' : 'light';
		document.documentElement.setAttribute('data-theme', theme);
		// Persiste 1 ano; o hooks.server.ts estampa no próximo SSR (sem flash).
		document.cookie = `mv-theme=${theme}; path=/; max-age=31536000; samesite=lax`;
	}
</script>

<button
	type="button"
	onclick={toggle}
	aria-label={dark ? 'Ativar tema claro' : 'Ativar tema escuro'}
	title="Tema"
	class={cls}
>
	{#if dark}<Sun size={iconSize} />{:else}<Moon size={iconSize} />{/if}
</button>
