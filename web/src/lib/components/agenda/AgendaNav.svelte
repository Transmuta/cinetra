<script lang="ts">
	// Barra de navegação da agenda (protótipo :1546): ← · "Hoje" · → · rótulo contextual ·
	// segmented Dia | Semana | Mês | Lista.
	//
	// A barra não sabe navegar: ela diz PARA ONDE (data, visão) e a rota decide como (goto +
	// replaceState). O passo de cada seta depende da visão — ±1 dia, ±7 dias, ±1 mês — e mora
	// em `shiftByView`, testado à parte.
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import { VIEWS, VIEW_LABELS, shiftByView, viewLabel, type AgendaView } from '$lib/agenda-views';

	let {
		date,
		today,
		view = 'dia',
		onDate,
		onView
	}: {
		date: string;
		today: string;
		view?: AgendaView;
		onDate: (date: string) => void;
		onView: (view: AgendaView) => void;
	} = $props();

	const label = $derived(viewLabel(date, today, view));
	const isToday = $derived(date === today);

	// O rótulo das setas acompanha a visão: numa agenda mensal, "Dia anterior" seria mentira
	// para quem navega por leitor de tela.
	//
	// As duas formas vêm do MESMO registro. O botão "anterior" reconstruía o mapa por ternário
	// aninhado sobre o valor do outro — então uma quinta visão em `VIEWS` deixaria o "próximo"
	// certo e o "anterior" caindo calado no `else`, anunciando "Dia anterior".
	const PASSO: Record<AgendaView, { curto: string; capitalizado: string }> = {
		dia: { curto: 'dia', capitalizado: 'Dia' },
		lista: { curto: 'dia', capitalizado: 'Dia' },
		semana: { curto: 'semana', capitalizado: 'Semana' },
		mes: { curto: 'mês', capitalizado: 'Mês' }
	};
</script>

<div class="flex flex-wrap items-center gap-2 border-b border-edge bg-surface px-4 py-2.5">
	<div class="flex items-center gap-1">
		<button
			type="button"
			aria-label="{PASSO[view].capitalizado} anterior"
			onclick={() => onDate(shiftByView(date, view, -1))}
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
			aria-label="Próximo {PASSO[view].curto}"
			onclick={() => onDate(shiftByView(date, view, 1))}
			class="grid size-8 place-items-center rounded-lg border border-edge bg-surface text-muted hover:bg-surface-2"
		>
			<ChevronRight size={16} />
		</button>
	</div>

	<div class="min-w-0 flex-1 truncate text-[13.5px] font-semibold first-letter:uppercase">
		{label}
	</div>

	<div class="flex items-center gap-0.5 rounded-lg border border-edge bg-surface-2 p-0.5">
		{#each VIEWS as key (key)}
			<button
				type="button"
				aria-current={key === view ? 'page' : undefined}
				onclick={() => onView(key)}
				class="rounded-md px-2.5 py-1 text-[12.5px] font-semibold {key === view
					? 'bg-surface text-ink shadow-sm'
					: 'text-muted hover:text-ink'}"
			>
				{VIEW_LABELS[key]}
			</button>
		{/each}
	</div>
</div>
