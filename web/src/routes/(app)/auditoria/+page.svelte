<script lang="ts">
	import { page as pageState } from '$app/state';
	import { navigateQuery } from '$lib/querystring';
	import Paginacao from '$lib/components/Paginacao.svelte';
	import EstadoVazio from '$lib/components/EstadoVazio.svelte';
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

</script>

<svelte:head><title>Auditoria · Cinetra</title></svelte:head>

<div class="mx-auto w-full max-w-2xl px-4 py-6 sm:px-6">
	<header class="mb-4">
		<!-- `h2` (ACC-22): o `h1` da página é o do topbar, que já diz "Auditoria" — dois `h1` com o
		     mesmo texto na mesma tela não é hierarquia, é eco. As classes mandam no visual. -->
		<h2 class="flex items-center gap-2 text-xl font-semibold text-ink">
			<ScrollText size={19} class="text-accent-text" /> Auditoria
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
				<button type="button" onclick={clearAll} class="font-medium text-accent-text hover:underline">
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
		<EstadoVazio
			icone={SearchX}
			titulo={chips.length
				? 'Nenhuma alteração com esses filtros'
				: 'Nenhuma alteração registrada'}
		>
			{#snippet descricao()}
				{#if chips.length}
					Tente ampliar o período ou
					<button
						type="button"
						onclick={clearAll}
						class="font-medium text-accent-text hover:underline"
					>
						limpar os filtros
					</button>.
				{:else}
					Toda mudança, todo acesso a ficha e toda tentativa negada aparecem aqui, com quem fez e
					quando.
				{/if}
			{/snippet}
		</EstadoVazio>
	{/if}

	<Paginacao
		current={data.current}
		pageInfo={data.pageInfo}
		onPage={goPage}
		rotulo={auditPageLabel(data.pageInfo, data.entries.length, data.current)}
	/>
</div>
