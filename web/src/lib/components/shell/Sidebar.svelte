<script lang="ts">
	import MapPin from '@lucide/svelte/icons/map-pin';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import Clock from '@lucide/svelte/icons/clock';
	import CalendarOff from '@lucide/svelte/icons/calendar-off';
	import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
	import Users from '@lucide/svelte/icons/users';
	import { sectionOf, SECTION_TITLES, CONFIG_LINKS } from './nav';

	let { pathname, clinicName }: { pathname: string; clinicName?: string | null } = $props();

	const section = $derived(sectionOf(pathname));
	const title = $derived(section ? SECTION_TITLES[section] : '');

	// Um ícone por item de Configurações, na mesma ordem de CONFIG_LINKS.
	const CONFIG_ICONS = [Stethoscope, Clock, CalendarOff, SlidersHorizontal, Users];
</script>

<aside class="hidden w-64 shrink-0 flex-col border-r border-edge bg-surface md:flex">
	<div class="px-4 pb-1 pt-4">
		<div class="text-[17px] font-extrabold tracking-tight">Movimento</div>
		{#if clinicName}
			<div class="mt-0.5 flex items-center gap-1.5 text-[12px] text-faint">
				<MapPin size={11} />
				{clinicName}
			</div>
		{/if}
	</div>

	{#if title}
		<div class="flex items-center gap-1.5 px-4 pb-2 pt-2.5">
			<span class="text-[11px] font-bold uppercase tracking-[.06em] text-ink">{title}</span>
			<span class="size-[5px] rounded-full bg-teal"></span>
		</div>
	{/if}

	{#if section === 'config'}
		<nav aria-label="Configurações" class="flex-1 overflow-auto px-3 py-1">
			<div class="px-2 pb-1.5 pt-3 text-[10.5px] font-bold uppercase tracking-[.06em] text-faint">
				Ajustes
			</div>
			{#each CONFIG_LINKS as link, i (link.href)}
				{@const Icon = CONFIG_ICONS[i]}
				{@const isActive = pathname === link.href}
				<a
					href={link.href}
					aria-current={isActive ? 'page' : undefined}
					class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-[7px] text-[13px] {isActive
						? 'bg-surface-2 font-semibold text-ink'
						: 'font-medium text-muted hover:bg-surface-2'}"
				>
					<span class={isActive ? 'text-teal-text' : 'text-faint'}><Icon size={15} /></span>
					<span class="flex-1 truncate">{link.label}</span>
				</a>
			{/each}
		</nav>
	{/if}
</aside>
