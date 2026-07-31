<script lang="ts">
	// Visão Semana (protótipo `renderWeek` :1732), com duas divergências decididas:
	//
	//  - **7 dias, não 6** (A-D11). O protótipo nunca mostrava domingo; clínica que abre
	//    domingo existe, e o dia fechado aparece marcado como tal.
	//  - **A barra é ocupação real** (A-D12), não `n/45`. O 45 era constante mágica, e o mês
	//    normalizava pelo pico — a mesma quantidade pintava diferente nas duas visões.
	//
	// Não é grid temporal: é contador. Clicar num cartão abre aquele dia na visão Dia.
	import { weekDays, dayTotals, type DayCount } from '$lib/agenda-views';
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
		/** Abrir o dia (a rota decide como navegar). */
		onPick: (date: string) => void;
		onShowAll: () => void;
	} = $props();

	// Sem nenhuma coluna visível, os totais dariam capacidade 0 em todo dia e o cartão diria
	// "Sem expediente" — afirmando que a CLÍNICA não abre, quando quem sumiu foram os
	// profissionais. Mesmo estado da visão Dia (doc 25 §6).
	const semColunas = $derived(professionals.filter((p) => !hidden.includes(p.id)).length === 0);

	const DIA_SEMANA = new Intl.DateTimeFormat('pt-BR', { weekday: 'short', timeZone: 'UTC' });

	// A grade sai do CALENDÁRIO, não da resposta: um dia sem linha na resposta ainda é um dia
	// da semana e precisa de cartão. Sem isto, a semana encolheria conforme a API respondesse.
	const cards = $derived.by(() => {
		const porData = new Map(dayTotals(days, hidden).map((d) => [d.date, d]));

		return weekDays(date).map((d) => ({
			date: d,
			label: DIA_SEMANA.format(new Date(`${d}T12:00:00Z`)).replace('.', ''),
			numero: d.slice(8, 10),
			isToday: d === today,
			isSelected: d === date,
			totals: porData.get(d) ?? {
				date: d,
				total: 0,
				ocupado_minutos: 0,
				capacidade_minutos: 0,
				rate: null
			}
		}));
	});

	const pct = (rate: number | null) => (rate === null ? null : `${Math.round(rate * 100)}%`);
</script>

{#if semColunas}
	<AgendaEmptyState {onShowAll} />
{:else}
<div class="grid grid-cols-2 gap-2.5 p-4 sm:grid-cols-4 lg:grid-cols-7">
	{#each cards as card (card.date)}
		<button
			type="button"
			onclick={() => onPick(card.date)}
			aria-current={card.isToday ? 'date' : undefined}
			class="flex flex-col gap-2 rounded-xl border p-3 text-left transition-colors {card.isSelected
				? 'border-accent-border bg-accent-subtle'
				: 'border-edge bg-surface hover:bg-surface-2'}"
		>
			<div class="flex items-baseline justify-between gap-1">
				<span class="text-[11px] font-medium text-faint capitalize">{card.label}</span>
				{#if card.isToday}
					<span class="text-[10px] font-bold tracking-wide text-accent-text uppercase">hoje</span>
				{/if}
			</div>

			<div class="font-mono text-[20px] leading-none font-semibold tabular-nums">
				{card.numero}
			</div>

			{#if card.totals.rate === null}
				<!-- Fechado ≠ vazio. Um "0 agend." num domingo fechado convida a marcar num dia
				     em que ninguém atende. -->
				<div class="text-[12px] font-semibold text-faint">Sem expediente</div>
			{:else}
				<div
					class="text-[12px] font-semibold {card.totals.total > 0 ? 'text-accent-text' : 'text-faint'}"
				>
					{card.totals.total} agend.
				</div>
			{/if}

			<OccupancyBar
				rate={card.totals.rate}
				title="Ocupação de {card.date}: {pct(card.totals.rate) ?? 'sem expediente'}"
			/>

			{#if card.totals.rate !== null}
				<div class="text-[10.5px] text-muted tabular-nums">
					{pct(card.totals.rate)} ocupado
				</div>
			{/if}
		</button>
	{/each}
</div>
{/if}
