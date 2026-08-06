<script lang="ts">
	// Fila (doc 25, Entrega 5). "Adicionar à fila" (viaja por `?novo=1`, o gatilho que a página lê
	// para abrir o modal) + o filtro por prioridade com contagens.
	import { page } from '$app/state';
	import Clock4 from '@lucide/svelte/icons/clock-4';
	import Plus from '@lucide/svelte/icons/plus';
	import Inbox from '@lucide/svelte/icons/inbox';
	import {
		canManageWaitlist,
		priorityCounts,
		PRIORITY_META,
		type Entry,
		type PriorityFilter,
		type WaitlistCounts
	} from '$lib/waitlist';
	import type { Papel } from '$lib/session';

	// Aqui `counts` é `WaitlistCounts` — a mesma chave que em Pacientes é `PatientCounts`. Ver a
	// nota lá: um arquivo por seção é o que torna esse contrato declarável (doc 94 §3.5).
	const dados = $derived(
		page.data as { counts?: WaitlistCounts; waitlist?: Entry[]; me?: { papel?: Papel | null } }
	);

	const FILA_FILTERS: ReadonlyArray<{ key: PriorityFilter; label: string }> = [
		{ key: 'todas', label: 'Todas' },
		{ key: 'urgente', label: 'Urgente' },
		{ key: 'alta', label: 'Alta' },
		{ key: 'normal', label: 'Normal' },
		{ key: 'baixa', label: 'Baixa' }
	];

	// As contagens vêm do SERVIDOR desde que a fila foi paginada (F6): contar `waitlist` contaria
	// só a página aberta, e o segmento "Urgente (3)" viraria "(1)" ao virar de página. O
	// `priorityCounts` local fica como fallback para quem chegar antes do load.
	const waitlist = $derived(dados.waitlist ?? []);
	const filaCounts = $derived(dados.counts ?? priorityCounts(waitlist));
	const canManageFila = $derived(canManageWaitlist(dados.me?.papel));
	const filaPrio = $derived(page.url.searchParams.get('prio') ?? 'todas');
	const filaHref = (key: PriorityFilter) => (key === 'todas' ? '/fila' : `/fila?prio=${key}`);
</script>

	<div class="flex-1 overflow-auto px-3 py-1">
		{#if canManageFila}
			<a
				href="/fila?novo=1"
				class="mb-2 flex items-center justify-center gap-1.5 rounded-controle bg-ink px-3 py-2.5 text-corpo font-semibold text-canvas hover:opacity-90"
			>
				<Plus size={15} /> Adicionar à fila
			</a>
		{/if}

		<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
			Prioridade
		</div>
		{#each FILA_FILTERS as fil (fil.key)}
			{@const isActive = filaPrio === fil.key}
			<a
				href={filaHref(fil.key)}
				aria-current={isActive ? 'page' : undefined}
				class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo {isActive
					? 'bg-surface-2 font-semibold text-ink'
					: 'font-medium text-muted hover:bg-surface-2'}"
			>
				<!-- Bolinha na cor da prioridade (hex fixo do protótipo); "Todas" leva o relógio. -->
				{#if fil.key === 'todas'}
					<span class={isActive ? 'text-accent-text' : 'text-faint'}><Clock4 size={15} /></span>
				{:else}
					<span class="grid size-[15px] place-items-center">
						<span class="size-2.5 rounded-full" style="background:{PRIORITY_META[fil.key].color}"></span>
					</span>
				{/if}
				<span class="flex-1 truncate">{fil.label}</span>
				<span class="font-mono text-meta text-faint">{filaCounts[fil.key]}</span>
			</a>
		{/each}
	</div>