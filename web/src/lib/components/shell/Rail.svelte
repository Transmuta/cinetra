<script lang="ts">
	import CalendarDays from '@lucide/svelte/icons/calendar-days';
	import Users from '@lucide/svelte/icons/users';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import Clock4 from '@lucide/svelte/icons/clock-4';
	import ChartBar from '@lucide/svelte/icons/chart-bar';
	import Settings from '@lucide/svelte/icons/settings';
	import Bell from '@lucide/svelte/icons/bell';
	import Mark from '$lib/components/Mark.svelte';
	import ThemeToggle from '$lib/components/ThemeToggle.svelte';
	import { sectionOf, RAIL_ITEMS, type Section } from './nav';

	let { pathname, theme }: { pathname: string; theme?: string | null } = $props();

	const active = $derived(sectionOf(pathname));

	const ICONS: Record<Section, typeof CalendarDays> = {
		agenda: CalendarDays,
		pacientes: Users,
		profissionais: Stethoscope,
		fila: Clock4,
		relatorios: ChartBar,
		config: Settings
	};
</script>

<nav
	aria-label="Navegação principal"
	class="flex w-14 shrink-0 flex-col items-center gap-1 bg-rail py-3"
>
	<!-- Marca Cinetra (símbolo) sobre ladrilho claro, p/ contraste no rail escuro. -->
	<a
		href="/"
		title="Cinetra"
		class="mb-2.5 grid size-[34px] place-items-center rounded-[9px] bg-white"
	>
		<Mark class="size-6" />
	</a>

	{#each RAIL_ITEMS as item (item.section)}
		{@const Icon = ICONS[item.section]}
		{@const isActive = active === item.section}
		<a
			href={item.href}
			title={item.label}
			aria-current={isActive ? 'page' : undefined}
			class="relative grid size-10 place-items-center rounded-lg transition-colors {isActive
				? 'bg-rail-item text-white'
				: 'text-white/60 hover:bg-rail-item/60 hover:text-white'}"
		>
			<Icon size={19} />
			{#if isActive}
				<span class="absolute right-1.5 top-1.5 size-[5px] rounded-full bg-teal"></span>
			{/if}
		</a>
	{/each}

	<div class="flex-1"></div>

	<!-- Notificações (placeholder visual do protótipo; sem feature ainda). -->
	<button
		type="button"
		title="Notificações"
		class="relative grid size-10 place-items-center rounded-lg text-white/60 transition-colors hover:bg-rail-item/60 hover:text-white"
	>
		<Bell size={18} />
		<span class="absolute right-[9px] top-[9px] size-[7px] rounded-full border-[1.5px] border-rail bg-teal"></span>
	</button>

	<!-- Tema: no rodapé do rail (o avatar do usuário mora no topbar). -->
	<ThemeToggle initial={theme} variant="rail" />
</nav>
