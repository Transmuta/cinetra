<script lang="ts">
	import { page } from '$app/state';
	import Rail from '$lib/components/shell/Rail.svelte';
	import Sidebar from '$lib/components/shell/Sidebar.svelte';
	import Topbar from '$lib/components/shell/Topbar.svelte';
	import { activeMembership } from '$lib/session';
	import type { LayoutData } from './$types';

	let { data, children }: { data: LayoutData; children: import('svelte').Snippet } = $props();

	const me = $derived(data.me);
	const clinicName = $derived(activeMembership(me)?.clinic_nome ?? null);
	const pathname = $derived(page.url.pathname);
	const theme = $derived((page.data.theme as string | null) ?? null);
</script>

<div class="flex h-dvh w-full overflow-hidden bg-canvas text-ink">
	<Rail {pathname} />
	<Sidebar {pathname} {clinicName} />
	<div class="flex min-w-0 flex-1 flex-col">
		<Topbar {pathname} {me} {clinicName} {theme} />
		<main class="flex-1 overflow-auto">
			{@render children()}
		</main>
	</div>
</div>
