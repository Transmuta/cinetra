<script lang="ts">
	// Visão Mês (protótipo `renderMonth` :1749). Mesma fórmula da Semana (A-D12): a barra é
	// ocupação real, não `n / pico do mês` — normalizar pelo pico faz a mesma quantidade
	// pintar diferente conforme o mês, e um mês fraco parecer cheio.
	//
	// Semanas inteiras a partir de domingo, cortadas nas linhas que o mês usa. As células de
	// fora do mês vêm SEM contagem: a janela pedida ao servidor é o mês (o teto é de 31 dias,
	// e a grade chega a 42) — elas navegam, mas não afirmam número nenhum.
	import { monthGrid, dayTotals, type DayCount } from '$lib/agenda-views';
	import type { AgendaProfessional } from '$lib/agenda';
	import OccupancyBar from './OccupancyBar.svelte';
	import AgendaEmptyState from './AgendaEmptyState.svelte';

	let {
		date,
		today,
		days,
		professionals,
		hidden = [],
		onPick,
		onShowAll
	}: {
		date: string;
		today: string;
		days: DayCount[];
		professionals: AgendaProfessional[];
		hidden?: string[];
		onPick: (date: string) => void;
		onShowAll: () => void;
	} = $props();

	// Ver `WeekView`: sem coluna visível, todo dia do mês viraria "fechado" — uma afirmação
	// sobre a clínica que não é verdade.
	const semColunas = $derived(professionals.filter((p) => !hidden.includes(p.id)).length === 0);

	const CABECALHO = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];

	const cells = $derived.by(() => {
		const porData = new Map(dayTotals(days, hidden).map((d) => [d.date, d]));

		return monthGrid(date).map((cell) => ({
			...cell,
			numero: Number(cell.date.slice(8, 10)),
			isToday: cell.date === today,
			isSelected: cell.date === date,
			totals: porData.get(cell.date) ?? null
		}));
	});
</script>

{#if semColunas}
	<AgendaEmptyState {onShowAll} />
{:else}
<div class="flex h-full flex-col gap-1.5 p-4">
	<div class="grid grid-cols-7 gap-1.5">
		{#each CABECALHO as dia (dia)}
			<div class="text-center text-[11px] font-bold text-faint">{dia}</div>
		{/each}
	</div>

	<div class="grid min-h-0 flex-1 auto-rows-fr grid-cols-7 gap-1.5">
		{#each cells as cell (cell.date)}
			<button
				type="button"
				onclick={() => onPick(cell.date)}
				aria-current={cell.isToday ? 'date' : undefined}
				aria-label="{cell.date}{cell.totals ? `, ${cell.totals.total} agendamentos` : ''}"
				class="flex min-h-[74px] flex-col gap-1 rounded-lg border p-1.5 text-left {cell.isSelected
					? 'border-teal-border bg-teal-subtle'
					: cell.inMonth
						? 'border-edge bg-surface hover:bg-surface-2'
						: 'border-edge bg-surface-2'}"
				style={cell.inMonth ? '' : 'opacity:.5'}
			>
				<span
					class="grid size-[26px] place-items-center rounded-full font-mono text-[13px] font-semibold tabular-nums {cell.isToday
						? 'bg-teal text-on-solid'
						: cell.inMonth
							? 'text-ink'
							: 'text-faint'}"
				>
					{cell.numero}
				</span>

				{#if cell.totals && cell.totals.total > 0}
					<div class="mt-auto flex flex-col gap-1">
						<span class="text-[10.5px] font-semibold text-teal-text">
							{cell.totals.total} agend.
						</span>
						<OccupancyBar rate={cell.totals.rate} title="Ocupação de {cell.date}" />
					</div>
				{:else if cell.totals && cell.totals.rate === null}
					<!-- Dia dentro do mês, mas sem expediente. O travessão do protótipo diria
					     "nenhum agendamento", que não é a mesma informação. -->
					<span class="mt-auto text-[10.5px] text-faint">fechado</span>
				{/if}
				<!-- Dia aberto e vazio não mostra nada: uma barra sempre em zero e um "agend."
				     sem número são ruído que não informa, repetido 20 vezes por mês. -->
			</button>
		{/each}
	</div>
</div>
{/if}
