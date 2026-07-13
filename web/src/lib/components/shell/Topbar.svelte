<script lang="ts">
	import ThemeToggle from '$lib/components/ThemeToggle.svelte';
	import { sectionOf, SECTION_TITLES } from './nav';
	import { initials } from '$lib/format';
	import type { Me } from '$lib/session';

	let {
		pathname,
		me,
		clinicName,
		theme
	}: { pathname: string; me: Me; clinicName?: string | null; theme?: string | null } = $props();

	const section = $derived(sectionOf(pathname));
	const title = $derived(section ? SECTION_TITLES[section] : 'Movimento');
	const avatarInitials = $derived(initials(me.user.nome));
</script>

<header
	class="flex h-14 shrink-0 items-center justify-between border-b border-edge bg-surface px-5"
>
	<h1 class="text-[15px] font-bold">{title}</h1>

	<div class="flex items-center gap-3">
		{#if clinicName}
			<span
				class="hidden rounded-full bg-teal-subtle px-2.5 py-1 text-[12px] font-semibold text-teal-text sm:inline"
			>
				{clinicName}
			</span>
		{/if}
		<ThemeToggle initial={theme} />
		<div class="flex items-center gap-2">
			<div
				class="grid size-8 place-items-center rounded-full bg-primary text-[11px] font-bold text-on-primary"
			>
				{avatarInitials}
			</div>
			<div class="hidden leading-tight sm:block">
				<div class="text-[13px] font-semibold">{me.user.nome}</div>
				<div class="text-[11px] text-faint">{me.user.email}</div>
			</div>
		</div>
	</div>
</header>
