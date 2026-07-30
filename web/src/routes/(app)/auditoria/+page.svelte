<script lang="ts">
	import { page as pageState } from '$app/state';
	import { navigateQuery } from '$lib/querystring';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import ScrollText from '@lucide/svelte/icons/scroll-text';
	import SearchX from '@lucide/svelte/icons/search-x';
	import X from '@lucide/svelte/icons/x';
	import AuditEntry from '$lib/components/audit/AuditEntry.svelte';
	import { activeChips, groupByDay, auditPageLabel, AUDIT_BASE } from '$lib/audit';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	// O fuso da clínica ativa (ADR-009), do layout — a trilha é formatada no relógio da clínica,
	// nunca no do browser. `me.timezone` pode ser null em bordas; cai no fuso do projeto.
	const timezone = $derived(data.me.timezone ?? 'America/Sao_Paulo');

	const groups = $derived(groupByDay(data.entries, timezone, data.hoje));

	// Os FILTROS moram na sidebar (`$lib/components/shell/Sidebar.svelte`), como em Profissionais,
	// Pacientes, Fila, Relatórios e Notificações. Aqui eles só são ecoados como chips: filtro que
	// mora fora do corpo precisa de eco dentro dele, senão uma lista curta lê como "não aconteceu
	// nada" em vez de "você está filtrando".
	const chips = $derived(
		activeChips({
			resource: data.resource,
			action: data.action,
			period: data.period,
			autor: data.autor,
			recordId: data.recordId,
			autores: data.autores
		})
	);

	function navigate(patch: Record<string, string | null>) {
		navigateQuery(AUDIT_BASE, pageState.url.searchParams, patch);
	}

	function goPage(n: number) {
		navigate({ page: n > 1 ? String(n) : null });
	}

	// Limpar um chip zera a página junto: a página 3 de um recorte não existe no recorte maior.
	function clearChip(key: string) {
		navigate({ [key]: null, page: null });
	}

	function clearAll() {
		navigate({ resource: null, periodo: null, acao: null, autor: null, record_id: null, page: null });
	}

	const navBtn =
		'inline-flex items-center gap-1 rounded-lg border border-edge bg-surface px-2.5 py-1.5 text-[12.5px] font-semibold text-ink hover:bg-surface-2 disabled:opacity-40 disabled:hover:bg-surface';
</script>

<svelte:head><title>Auditoria · Cinetra</title></svelte:head>

<div class="mx-auto w-full max-w-2xl px-4 py-6 sm:px-6">
	<header class="mb-4">
		<!-- `h2` (ACC-22): o `h1` da página é o do topbar, que já diz "Auditoria" — dois `h1` com o
		     mesmo texto na mesma tela não é hierarquia, é eco. As classes mandam no visual. -->
		<h2 class="flex items-center gap-2 text-xl font-semibold text-ink">
			<ScrollText size={19} class="text-teal-text" /> Auditoria
		</h2>
		<p class="mt-0.5 text-sm text-muted">
			Quem mudou o quê, quem abriu o quê, e quando — o histórico da clínica.
		</p>
	</header>

	{#if chips.length}
		<div class="mb-3 flex flex-wrap items-center gap-2 text-[12.5px]">
			{#each chips as chip (chip.key)}
				<span
					class="inline-flex items-center gap-1.5 rounded-full border border-edge bg-surface-2 px-2.5 py-1 text-muted"
				>
					{chip.label}
					<button
						type="button"
						onclick={() => clearChip(chip.key)}
						aria-label="Remover filtro: {chip.label}"
						class="text-faint hover:text-ink"
					>
						<X size={12} />
					</button>
				</span>
			{/each}
			{#if chips.length > 1}
				<button type="button" onclick={clearAll} class="font-medium text-teal-text hover:underline">
					Limpar filtros
				</button>
			{/if}
		</div>
	{/if}

	{#if groups.length}
		<div class="flex flex-col gap-4">
			{#each groups as group (group.day)}
				<section>
					<h2 class="mb-1.5 px-1 text-[11px] font-bold uppercase tracking-[.06em] text-faint">
						{group.heading}
					</h2>
					<div class="divide-y divide-edge overflow-hidden rounded-xl border border-edge bg-surface">
						{#each group.entries as entry (entry.id)}
							<AuditEntry {entry} {timezone} />
						{/each}
					</div>
				</section>
			{/each}
		</div>
	{:else}
		<!-- O vazio diz QUAL vazio: "nenhuma alteração registrada" com um filtro ligado faria quem
		     tem a trilha cheia achar que a clínica não fez nada (lição da caixa, doc 53). -->
		<div
			class="flex flex-col items-center justify-center rounded-xl border border-edge bg-surface py-16 text-center"
		>
			<SearchX size={28} class="text-faint" />
			<p class="mt-3 text-sm font-medium text-ink">
				{chips.length ? 'Nenhuma alteração com esses filtros' : 'Nenhuma alteração registrada'}
			</p>
			<p class="mt-1 text-sm text-muted">
				{#if chips.length}
					Tente ampliar o período ou
					<button type="button" onclick={clearAll} class="font-medium text-teal-text hover:underline">
						limpar os filtros
					</button>.
				{:else}
					Toda mudança, todo acesso a ficha e toda tentativa negada aparecem aqui, com quem fez
					e quando.
				{/if}
			</p>
		</div>
	{/if}

	<!-- Paginação: só quando há mais de uma página. -->
	{#if data.pageInfo.more || data.current > 1}
		<div class="mt-4 flex items-center gap-3">
			<span class="font-mono text-[11.5px] text-faint">
				{auditPageLabel(data.pageInfo, data.entries.length, data.current)}
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
