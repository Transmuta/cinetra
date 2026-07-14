<script lang="ts">
	import { page } from '$app/state';
	import { afterNavigate } from '$app/navigation';
	import Rail from '$lib/components/shell/Rail.svelte';
	import Sidebar from '$lib/components/shell/Sidebar.svelte';
	import Topbar from '$lib/components/shell/Topbar.svelte';
	import Toast from '$lib/components/Toast.svelte';
	import { activeMembership } from '$lib/session';
	import type { LayoutData } from './$types';

	let { data, children }: { data: LayoutData; children: import('svelte').Snippet } = $props();

	const me = $derived(data.me);
	const clinicName = $derived(activeMembership(me)?.clinic_nome ?? null);
	const pathname = $derived(page.url.pathname);
	const theme = $derived((page.data.theme as string | null) ?? null);

	// Abaixo de `lg`, rail+sidebar viram uma gaveta aberta pelo hambúrguer do topbar (o
	// espaço não comporta os 312px de cromo + conteúdo). Navegar fecha a gaveta.
	let drawerOpen = $state(false);
	afterNavigate(() => (drawerOpen = false));
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && (drawerOpen = false)} />

<div class="flex h-dvh w-full overflow-hidden bg-canvas text-ink">
	<!-- Desktop (≥lg): rail + sidebar fixos. -->
	<div class="hidden lg:flex">
		<Rail {pathname} {theme} />
		<Sidebar {pathname} {clinicName} />
	</div>

	<div class="flex min-w-0 flex-1 flex-col">
		<Topbar {pathname} {me} onMenu={() => (drawerOpen = true)} />
		<main class="flex-1 overflow-auto">
			{@render children()}
		</main>
	</div>
</div>

<!-- Toast global do shell (feedback de ações; $lib/toast.svelte.ts) -->
<Toast />

<!-- Mobile (<lg): gaveta com rail + sidebar sobre um backdrop. -->
{#if drawerOpen}
	<div class="fixed inset-0 z-40 flex lg:hidden">
		<button
			type="button"
			aria-label="Fechar menu"
			class="absolute inset-0 bg-black/40"
			onclick={() => (drawerOpen = false)}
		></button>
		<div class="relative flex h-full shadow-pop">
			<Rail {pathname} {theme} />
			<Sidebar {pathname} {clinicName} />
		</div>
	</div>
{/if}
