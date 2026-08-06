<script lang="ts">
	// Ajustes da clínica. É o único ramo sem `page.data`: os itens são fixos e o ativo sai do
	// próprio caminho.
	import Building2 from '@lucide/svelte/icons/building-2';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import Clock from '@lucide/svelte/icons/clock';
	import CalendarOff from '@lucide/svelte/icons/calendar-off';
	import Send from '@lucide/svelte/icons/send';
	import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
	import { CONFIG_LINKS } from '../nav';

	let { pathname }: { pathname: string } = $props();

	// Ícone de cada item por HREF (não por índice — assim acrescentar ou tirar um item não
	// desalinha um array paralelo).
	const CONFIG_ICONS: Record<string, typeof Building2> = {
		'/configuracoes/clinica': Building2,
		'/configuracoes/tipos': Stethoscope,
		'/configuracoes/horario': Clock,
		'/configuracoes/excecoes': CalendarOff,
		'/configuracoes/comunicacao': Send,
		'/configuracoes/equipe': SlidersHorizontal
	};
</script>

	<nav aria-label="Configurações" class="flex-1 overflow-auto px-3 py-1">
		<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
			Ajustes
		</div>
		{#each CONFIG_LINKS as link (link.href)}
			{@const Icon = CONFIG_ICONS[link.href]}
			{@const isActive = pathname === link.href}
			<a
				href={link.href}
				aria-current={isActive ? 'page' : undefined}
				class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo {isActive
					? 'bg-surface-2 font-semibold text-ink'
					: 'font-medium text-muted hover:bg-surface-2'}"
			>
				<span class={isActive ? 'text-accent-text' : 'text-faint'}><Icon size={15} /></span>
				<span class="flex-1 truncate">{link.label}</span>
			</a>
		{/each}
	</nav>