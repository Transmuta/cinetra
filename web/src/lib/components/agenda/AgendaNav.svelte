<script lang="ts">
	// Barra de navegação da agenda (protótipo :1546): ← · "Hoje" · → · rótulo contextual ·
	// segmented Dia | Semana | Mês | Lista.
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import { dayLabel, shiftDate } from '$lib/agenda';

	let {
		date,
		today,
		onDate
	}: {
		date: string;
		today: string;
		/** A rota decide como navegar (goto + replaceState); a barra só diz para onde. */
		onDate: (date: string) => void;
	} = $props();

	const label = $derived(dayLabel(date, today));
	const isToday = $derived(date === today);

	// Entrega 1 é só a visão Dia (A1). As outras três aparecem para não mentir sobre o modelo
	// de navegação, mas desabilitadas COM explicação — botão morto e mudo é pior que ausente.
	const VIEWS = [
		{ key: 'dia', label: 'Dia', ready: true },
		{ key: 'semana', label: 'Semana', ready: false },
		{ key: 'mes', label: 'Mês', ready: false },
		{ key: 'lista', label: 'Lista', ready: false }
	] as const;

	const EM_BREVE = 'Disponível na próxima entrega da agenda';
</script>

<div class="flex flex-wrap items-center gap-2 border-b border-edge bg-surface px-4 py-2.5">
	<div class="flex items-center gap-1">
		<button
			type="button"
			aria-label="Dia anterior"
			onclick={() => onDate(shiftDate(date, -1))}
			class="grid size-8 place-items-center rounded-lg border border-edge bg-surface text-muted hover:bg-surface-2"
		>
			<ChevronLeft size={16} />
		</button>

		<button
			type="button"
			onclick={() => onDate(today)}
			aria-current={isToday ? 'date' : undefined}
			class="h-8 rounded-lg border px-3 text-[12.5px] font-semibold {isToday
				? 'border-teal-border bg-teal-subtle text-teal-text'
				: 'border-edge bg-surface text-ink hover:bg-surface-2'}"
		>
			Hoje
		</button>

		<button
			type="button"
			aria-label="Próximo dia"
			onclick={() => onDate(shiftDate(date, 1))}
			class="grid size-8 place-items-center rounded-lg border border-edge bg-surface text-muted hover:bg-surface-2"
		>
			<ChevronRight size={16} />
		</button>
	</div>

	<div class="min-w-0 flex-1 truncate text-[13.5px] font-semibold first-letter:uppercase">
		{label}
	</div>

	<div class="flex items-center gap-0.5 rounded-lg border border-edge bg-surface-2 p-0.5">
		{#each VIEWS as view (view.key)}
			<button
				type="button"
				disabled={!view.ready}
				aria-current={view.ready ? 'page' : undefined}
				title={view.ready ? undefined : EM_BREVE}
				class="rounded-md px-2.5 py-1 text-[12.5px] font-semibold {view.ready
					? 'bg-surface text-ink shadow-sm'
					: 'text-faint disabled:cursor-not-allowed'}"
			>
				{view.label}
			</button>
		{/each}
	</div>
</div>
