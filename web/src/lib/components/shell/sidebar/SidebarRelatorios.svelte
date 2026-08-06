<script lang="ts">
	// Relatórios (doc 33 / `sbRelatorios` :1461): dois filtros — período e profissional. Ambos
	// viajam na URL (`?period=` / `?prof=`), como as outras seções; o load os lê. A lista de
	// profissionais vem do próprio relatório, então para o papel `profissional` ela degenera nele
	// mesmo e o filtro fica preso — o que a API já impõe (§3).
	import { page } from '$app/state';
	import Users from '@lucide/svelte/icons/users';
	import User from '@lucide/svelte/icons/user';
	import CalendarDays from '@lucide/svelte/icons/calendar-days';
	import CalendarRange from '@lucide/svelte/icons/calendar-range';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import { PERIOD_LABELS, professionalName } from '$lib/reports';
	import { avatarColor, avatarStyle } from '$lib/avatar';
	import type { Professional } from '$lib/professionals';

	const dados = $derived(page.data as { professionals?: Professional[] });

	const relProfs = $derived(dados.professionals ?? []);
	const relPeriod = $derived(page.url.searchParams.get('period') ?? 'mes');
	const relProf = $derived(page.url.searchParams.get('prof') ?? 'todos');

	const REL_PERIODS = [
		{ key: 'hoje', icon: CalendarDays },
		{ key: 'semana', icon: CalendarRange },
		{ key: 'mes', icon: CalendarRange },
		{ key: 'trimestre', icon: CalendarRange }
	] as const;

	// O link preserva o OUTRO filtro e omite os defaults ('mes' / 'todos') para a URL ficar limpa.
	function relHref(next: { period?: string; prof?: string }): string {
		const period = next.period ?? relPeriod;
		const prof = next.prof ?? relProf;
		const partes: string[] = [];
		if (period && period !== 'mes') partes.push(`period=${period}`);
		if (prof && prof !== 'todos') partes.push(`prof=${encodeURIComponent(prof)}`);
		return partes.length ? `/relatorios?${partes.join('&')}` : '/relatorios';
	}
</script>

	<div class="flex-1 overflow-auto px-3 py-1">
		<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
			Período
		</div>
		{#each REL_PERIODS as per (per.key)}
			{@const isActive = relPeriod === per.key}
			<a
				href={relHref({ period: per.key })}
				aria-current={isActive ? 'page' : undefined}
				class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo {isActive
					? 'bg-surface-2 font-semibold text-ink'
					: 'font-medium text-muted hover:bg-surface-2'}"
			>
				<span class={isActive ? 'text-accent-text' : 'text-faint'}><per.icon size={15} /></span>
				<span class="flex-1 truncate">{PERIOD_LABELS[per.key]}</span>
			</a>
		{/each}

		<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
			Profissional
		</div>
		<a
			href={relHref({ prof: 'todos' })}
			aria-current={relProf === 'todos' ? 'page' : undefined}
			class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo {relProf ===
			'todos'
				? 'bg-surface-2 font-semibold text-ink'
				: 'font-medium text-muted hover:bg-surface-2'}"
		>
			<span class={relProf === 'todos' ? 'text-accent-text' : 'text-faint'}><Users size={15} /></span>
			<span class="flex-1 truncate">Todos</span>
		</a>
		{#each relProfs as prof (prof.id)}
			{@const isActive = relProf === prof.id}
			<a
				href={relHref({ prof: prof.id })}
				aria-current={isActive ? 'page' : undefined}
				class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo {isActive
					? 'bg-surface-2 font-semibold text-ink'
					: 'font-medium text-muted hover:bg-surface-2'}"
			>
				<span class="grid size-4 shrink-0 place-items-center rounded-full" style={avatarStyle(prof.cor_indice)}>
					<User size={10} />
				</span>
				<span class="flex-1 truncate">{professionalName(relProfs, prof.id)}</span>
			</a>
		{/each}
	</div>