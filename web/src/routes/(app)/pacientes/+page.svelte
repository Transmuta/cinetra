<script lang="ts">
	import { untrack, onDestroy } from 'svelte';
	import { page as pageState } from '$app/state';
	import { goto } from '$app/navigation';
	import Search from '@lucide/svelte/icons/search';
	import UserPlus from '@lucide/svelte/icons/user-plus';
	import Phone from '@lucide/svelte/icons/phone';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import { initials } from '$lib/format';
	import {
		canManagePatients,
		patientColor,
		prefNomes,
		stripTitle,
		pageLabel,
		type Patient
	} from '$lib/patients';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	// Gestão = owner/admin (some o "+" mobile para os demais; a sidebar já faz o mesmo).
	const canManage = $derived(canManagePatients(data.me.papel));

	// Busca e segmento vivem na URL e são resolvidos pelo SERVIDOR (a lista é paginada; filtrar
	// no cliente devolveria página furada). O input é local só para não piscar enquanto digita.
	let term = $state(untrack(() => data.q));
	let debounce: ReturnType<typeof setTimeout> | undefined;
	// Propositalmente NÃO é `$state`: só arbitra o sync abaixo, não alimenta a UI — e se fosse
	// reativo, o próprio efeito passaria a re-rodar quando ele mudasse, que é o oposto do que
	// se quer.
	let digitando = false;

	// Mantém o input em sinc com a URL: trocar de segmento na sidebar limpa a busca, e o campo
	// tem que acompanhar (senão mostraria um termo que não está mais sendo aplicado).
	// Mas NÃO sobrescreve enquanto há digitação pendente: com um load em voo, a resposta do
	// termo antigo chegaria depois da nova tecla e devolveria o input ao valor velho — a tecla
	// seguinte viraria "mai" em vez de "mari" (caractere perdido, não só flicker).
	$effect(() => {
		const q = data.q;
		if (!digitando) term = q;
	});

	// Aplica um patch na query string e navega. Chaves com valor vazio saem da URL.
	function navigate(patch: Record<string, string | null>) {
		const params = new URLSearchParams(pageState.url.searchParams);
		for (const [key, value] of Object.entries(patch)) {
			if (value === null || value === '') params.delete(key);
			else params.set(key, value);
		}
		const qs = params.toString();
		goto(qs ? `/pacientes?${qs}` : '/pacientes', {
			keepFocus: true,
			noScroll: true,
			replaceState: true
		});
	}

	// Digitar refaz a busca no servidor — com folga para não disparar a cada tecla. Mudar o
	// termo sempre volta para a página 1 (senão você cairia num offset que não existe mais).
	function onSearch(value: string) {
		term = value;
		digitando = true;
		clearTimeout(debounce);
		debounce = setTimeout(() => {
			digitando = false;
			navigate({ q: value.trim() || null, page: null });
		}, 300);
	}

	// Sem isto, sair da lista antes do debounce vencer (digitar e clicar numa linha em menos de
	// 300ms) deixa um timer órfão que chama `goto` e ARRASTA a pessoa de volta para a lista —
	// remontando a querystring a partir da URL da ficha, que já é outra.
	onDestroy(() => clearTimeout(debounce));

	function goPage(n: number) {
		navigate({ page: n > 1 ? String(n) : null });
	}

	const nomePorId = $derived(
		Object.fromEntries(data.professionals.map((p) => [p.id, p.nome])) as Record<string, string>
	);

	// Nome do profissional preferido para a coluna (1º + "+N"), sem o "Dr./Dra.".
	function prefLabel(p: Patient): string {
		const ns = prefNomes(p, nomePorId);
		if (!ns.length) return '—';
		const first = stripTitle(ns[0]);
		return ns.length > 1 ? `${first} +${ns.length - 1}` : first;
	}

	const COLS = 'md:grid-cols-[2.1fr_1.2fr_1.3fr_1fr]';
	const tagPill = 'rounded bg-surface-2 px-[7px] py-px text-[10.5px] text-muted border border-edge';
	const navBtn =
		'inline-flex items-center gap-1 rounded-lg border border-edge bg-surface px-2.5 py-1.5 text-[12.5px] font-semibold text-ink hover:bg-surface-2 disabled:opacity-40 disabled:hover:bg-surface';
</script>

<svelte:head><title>Pacientes · Cinetra</title></svelte:head>

<div class="px-4 py-4 md:px-[18px]">
	<!-- Toolbar: busca + "+" mobile (o "Novo paciente" cheio e o filtro moram na sidebar). -->
	<div class="mb-3.5 flex items-center gap-2">
		<div class="relative max-w-[380px] flex-1">
			<Search size={15} class="absolute top-1/2 left-2.5 -translate-y-1/2 text-faint" />
			<input
				value={term}
				oninput={(e) => onSearch(e.currentTarget.value)}
				placeholder="Buscar por nome, CPF ou telefone"
				aria-label="Buscar paciente"
				class="h-9 w-full rounded-lg border border-edge bg-surface pr-3 pl-8 text-[13px] text-ink"
			/>
		</div>
		{#if canManage}
			<a
				href="/pacientes/novo"
				title="Novo paciente"
				aria-label="Novo paciente"
				class="grid size-9 shrink-0 place-items-center rounded-lg bg-ink text-canvas hover:opacity-90 md:hidden"
			>
				<UserPlus size={17} />
			</a>
		{/if}
	</div>

	<div class="overflow-hidden rounded-[10px] border border-edge bg-surface">
		<!-- Cabeçalho (desktop) -->
		<div
			class="hidden gap-2 border-b border-edge px-3.5 pb-2.5 pt-3 text-[12px] font-medium text-faint md:grid {COLS}"
		>
			<span>Paciente</span><span>Telefone</span><span>Preferência</span><span>Tags</span>
		</div>

		{#each data.patients as p (p.id)}
			<!-- Desktop: linha em grid, clicável -->
			<a
				href="/pacientes/{p.id}"
				class="hidden items-center gap-2 border-b border-edge px-3.5 py-[9px] last:border-b-0 hover:bg-surface-2 md:grid {COLS} {p.ativo
					? ''
					: 'opacity-55'}"
			>
				<span class="flex min-w-0 items-center gap-2.5">
					<span
						class="grid size-7 shrink-0 place-items-center rounded-full text-[10px] font-bold text-white"
						style="background:{patientColor(p.cor_indice)}"
					>
						{initials(p.nome)}
					</span>
					<span class="min-w-0">
						<span class="block truncate text-[13px] font-semibold">
							{p.nome}{#if !p.ativo}<span class="ml-1 text-[10px] font-medium text-faint">(inativo)</span>{/if}
						</span>
						<span class="block font-mono text-[10px] text-faint">{p.cpf ?? '—'}</span>
					</span>
				</span>
				<span class="truncate font-mono text-[11px] text-muted">{p.tel ?? '—'}</span>
				<span class="truncate text-[12.5px] text-muted">{prefLabel(p)}</span>
				<span class="flex flex-wrap gap-1">
					{#if p.tags.length}
						<span class={tagPill}>{p.tags[0]}</span>
						{#if p.tags.length > 1}<span class="text-[10.5px] text-faint">+{p.tags.length - 1}</span>{/if}
					{:else}
						<span class="text-[11px] text-faint">—</span>
					{/if}
				</span>
			</a>

			<!-- Mobile: cartão empilhado -->
			<a
				href="/pacientes/{p.id}"
				class="flex flex-col gap-2 border-b border-edge px-3.5 py-3 last:border-b-0 md:hidden {p.ativo
					? ''
					: 'opacity-55'}"
			>
				<div class="flex items-center gap-2.5">
					<span
						class="grid size-8.5 shrink-0 place-items-center rounded-full text-[11px] font-bold text-white"
						style="background:{patientColor(p.cor_indice)}"
					>
						{initials(p.nome)}
					</span>
					<div class="min-w-0 flex-1">
						<div class="truncate text-[14px] font-semibold">
							{p.nome}{#if !p.ativo}<span class="ml-1 text-[10px] font-medium text-faint">(inativo)</span>{/if}
						</div>
						<div class="font-mono text-[10.5px] text-faint">{p.cpf ?? '—'}</div>
					</div>
				</div>
				<div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-[12px] text-muted">
					{#if p.tel}<span class="inline-flex items-center gap-1.5 font-mono"><Phone size={12} /> {p.tel}</span>{/if}
					{#if prefLabel(p) !== '—'}<span class="inline-flex min-w-0 items-center gap-1.5"><Stethoscope size={12} /> <span class="truncate">{prefLabel(p)}</span></span>{/if}
				</div>
				{#if p.tags.length}
					<div class="flex flex-wrap gap-1">
						{#each p.tags.slice(0, 3) as t (t)}<span class={tagPill}>{t}</span>{/each}
						{#if p.tags.length > 3}<span class="self-center text-[10.5px] text-faint">+{p.tags.length - 3}</span>{/if}
					</div>
				{/if}
			</a>
		{/each}

		{#if !data.patients.length}
			<div class="px-7 py-7 text-center text-[13px] text-faint">
				{#if data.q}
					Nenhum paciente encontrado para “{data.q}”.
				{:else if data.filter === 'inativos'}
					Nenhum paciente inativo.
				{:else if data.filter === 'resp'}
					Nenhum paciente com responsável legal.
				{:else}
					Nenhum paciente ainda.
				{/if}
			</div>
		{/if}
	</div>

	<!-- Rodapé de paginação: só aparece quando há mais de uma página. -->
	{#if data.pageInfo.more || data.current > 1}
		<div class="mt-3 flex items-center gap-3">
			<span class="font-mono text-[11.5px] text-faint">
				{pageLabel(data.pageInfo, data.patients.length)}
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
