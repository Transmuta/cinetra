<script lang="ts">
	import { page as pageState } from '$app/state';
	import { goto } from '$app/navigation';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import History from '@lucide/svelte/icons/history';
	import X from '@lucide/svelte/icons/x';
	import AuditEntry from '$lib/components/audit/AuditEntry.svelte';
	import { groupByDay, pageLabel, type ResourceFilter } from '$lib/audit';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	// O fuso da clínica ativa (ADR-009), do layout — a trilha é formatada no relógio da clínica,
	// nunca no do browser. `me.timezone` pode ser null em bordas; cai no fuso do projeto.
	const timezone = $derived(data.me.timezone ?? 'America/Sao_Paulo');

	const groups = $derived(groupByDay(data.entries, timezone));

	// As duas abas de tipo de recurso (o eixo `resource` do §11.4). Trocar reseta a página.
	const TABS: { key: ResourceFilter; label: string }[] = [
		{ key: 'appointment', label: 'Agendamentos' },
		{ key: 'attendance', label: 'Participantes' }
	];

	// Patch na query string + navegação (mesmo desenho da lista de Pacientes). Chaves vazias
	// saem da URL; trocar de recurso ou limpar filtro volta para a página 1.
	function navigate(patch: Record<string, string | null>) {
		const params = new URLSearchParams(pageState.url.searchParams);
		for (const [key, value] of Object.entries(patch)) {
			if (value === null || value === '') params.delete(key);
			else params.set(key, value);
		}
		const qs = params.toString();
		goto(qs ? `/configuracoes/auditoria?${qs}` : '/configuracoes/auditoria', {
			keepFocus: true,
			noScroll: true
		});
	}

	function selectResource(key: ResourceFilter) {
		navigate({ resource: key === 'appointment' ? null : key, page: null });
	}

	function goPage(n: number) {
		navigate({ page: n > 1 ? String(n) : null });
	}

	const navBtn =
		'inline-flex items-center gap-1 rounded-lg border border-edge bg-surface px-2.5 py-1.5 text-[12.5px] font-semibold text-ink hover:bg-surface-2 disabled:opacity-40 disabled:hover:bg-surface';
</script>

<svelte:head><title>Auditoria · Cinetra</title></svelte:head>

<div class="mx-auto max-w-[760px] px-4 py-4 md:px-[18px]">
	<header class="mb-3.5">
		<h1 class="flex items-center gap-2 text-[17px] font-bold tracking-tight text-ink">
			<History size={17} class="text-teal-text" /> Auditoria
		</h1>
		<p class="mt-0.5 text-[12.5px] text-faint">
			Quem mudou o quê, e quando — o histórico de agendamentos e participantes da clínica.
		</p>
	</header>

	<!-- Abas de tipo de recurso -->
	<div class="mb-3 flex items-center gap-1.5">
		{#each TABS as tab (tab.key)}
			{@const isActive = data.resource === tab.key}
			<button
				type="button"
				onclick={() => selectResource(tab.key)}
				aria-pressed={isActive}
				class="rounded-lg px-3 py-1.5 text-[13px] font-semibold {isActive
					? 'bg-ink text-canvas'
					: 'border border-edge bg-surface text-muted hover:bg-surface-2'}"
			>
				{tab.label}
			</button>
		{/each}
	</div>

	<!-- Chip do filtro por registro (deep-link "ver histórico deste agendamento"). -->
	{#if data.recordId}
		<div class="mb-3 flex items-center gap-2 text-[12.5px]">
			<span class="inline-flex items-center gap-1.5 rounded-full border border-edge bg-surface-2 px-2.5 py-1 text-muted">
				Histórico de um registro só
				<button
					type="button"
					onclick={() => navigate({ record_id: null, page: null })}
					aria-label="Limpar filtro de registro"
					class="text-faint hover:text-ink"
				>
					<X size={12} />
				</button>
			</span>
		</div>
	{/if}

	{#if groups.length}
		<div class="flex flex-col gap-4">
			{#each groups as group (group.day)}
				<section>
					<h2 class="mb-1.5 px-1 text-[11px] font-bold uppercase tracking-[.06em] text-faint">
						{group.heading}
					</h2>
					<div class="divide-y divide-edge overflow-hidden rounded-[10px] border border-edge bg-surface">
						{#each group.entries as entry (entry.id)}
							<AuditEntry {entry} {timezone} />
						{/each}
					</div>
				</section>
			{/each}
		</div>
	{:else}
		<div class="rounded-[10px] border border-edge bg-surface px-7 py-10 text-center text-[13px] text-faint">
			{#if data.recordId}
				Nenhuma alteração registrada para este registro.
			{:else if data.resource === 'attendance'}
				Nenhuma alteração de participante registrada ainda.
			{:else}
				Nenhuma alteração registrada ainda.
			{/if}
		</div>
	{/if}

	<!-- Paginação: só quando há mais de uma página. -->
	{#if data.pageInfo.more || data.current > 1}
		<div class="mt-4 flex items-center gap-3">
			<span class="font-mono text-[11.5px] text-faint">
				{pageLabel(data.pageInfo, data.entries.length)}
			</span>
			<div class="flex-1"></div>
			<button type="button" class={navBtn} disabled={data.current === 1} onclick={() => goPage(data.current - 1)}>
				<ChevronLeft size={14} /> Anterior
			</button>
			<button type="button" class={navBtn} disabled={!data.pageInfo.more} onclick={() => goPage(data.current + 1)}>
				Próxima <ChevronRight size={14} />
			</button>
		</div>
	{/if}
</div>
