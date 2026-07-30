<script lang="ts">
	// Barra de navegação da agenda (protótipo :1546): ← · "Hoje" · → · rótulo contextual ·
	// segmented Dia | Semana | Mês | Lista.
	//
	// A barra não sabe navegar: ela diz PARA ONDE (data, visão) e a rota decide como (goto +
	// replaceState). O passo de cada seta depende da visão — ±1 dia, ±7 dias, ±1 mês — e mora
	// em `shiftByView`, testado à parte.
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Plus from '@lucide/svelte/icons/plus';
	import { VIEWS, VIEW_LABELS, shiftByView, viewLabel, type AgendaView } from '$lib/agenda-views';
	import DayViewers from './DayViewers.svelte';

	let {
		date,
		today,
		view = 'dia',
		viewers = [],
		onDate,
		onView,
		onNew = undefined
	}: {
		date: string;
		today: string;
		view?: AgendaView;
		/** F5 — quem MAIS está com este dia aberto (só Dia/Lista recebem; ver `realtime.ts`). */
		viewers?: string[];
		onDate: (date: string) => void;
		onView: (view: AgendaView) => void;
		/**
		 * Abrir o modal de criar (ACC-03). Ausente = sem botão: é assim que quem não pode criar, ou
		 * o dia sem nenhuma coluna visível, deixa de ver uma ação que não levaria a nada.
		 */
		onNew?: () => void;
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

	<DayViewers nomes={viewers} />

	<!--
		ACC-03 (doc 83, WCAG 2.1.1 — nível A): até aqui criar agendamento existia SÓ por ponteiro —
		clique numa célula vazia (um `div onclick`) ou arraste. A sonda de teclado listou os focáveis
		do `<main>` da agenda: oito, todos de navegação. Este botão é o caminho de teclado, e reusa o
		mesmo modal do clique na célula (só sem preset de hora vinda do pixel).

		Só aparece com `onNew`: quem não pode criar (a policy é a autoridade; aqui é espelho de UX)
		não recebe o callback, e o botão não existe em vez de existir e recusar.
	-->
	{#if onNew}
		<button
			type="button"
			onclick={onNew}
			class="inline-flex h-8 shrink-0 items-center gap-1.5 rounded-lg bg-primary px-3 text-[12.5px] font-semibold text-on-primary hover:bg-primary-hover"
		>
			<Plus size={15} /> Novo agendamento
		</button>
	{/if}

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
