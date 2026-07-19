<script lang="ts">
	// Busca de paciente do modal (protótipo `patientField` :1941): ≥2 caracteres, no máximo
	// 10 resultados com o aviso "refine a busca".
	import { onDestroy } from 'svelte';
	import X from '@lucide/svelte/icons/x';
	import Search from '@lucide/svelte/icons/search';
	import { initials } from '$lib/format';
	import { avatarColor } from '$lib/avatar';
	import type { AgendaPatient, SearchResult } from '$lib/agenda';

	let {
		selected = [],
		multi = false,
		search,
		onPick,
		onRemove
	}: {
		selected?: AgendaPatient[];
		multi?: boolean;
		/** Injetado: a rota passa o fetch para `/agenda/pacientes`; o teste passa um duplo. */
		search: (q: string) => Promise<SearchResult>;
		onPick: (p: AgendaPatient) => void;
		onRemove: (id: string) => void;
	} = $props();

	/** Mínimo do protótipo (:1946): abaixo disso a busca varreria o cadastro a cada tecla. */
	const MIN_CHARS = 2;
	const DEBOUNCE_MS = 300;

	let term = $state('');
	let results = $state<AgendaPatient[]>([]);
	let total = $state(0);
	let searched = $state(false);
	let timer: ReturnType<typeof setTimeout> | undefined;

	function onInput(value: string) {
		term = value;
		clearTimeout(timer);

		if (value.trim().length < MIN_CHARS) {
			results = [];
			total = 0;
			searched = false;
			return;
		}

		timer = setTimeout(async () => {
			const r = await search(value.trim());
			results = r.patients;
			total = r.total;
			searched = true;
		}, DEBOUNCE_MS);
	}

	// Sem isto, fechar o modal entre a última tecla e os 300ms deixa um timer vivo que
	// dispara uma busca (e escreve em `$state`) num componente que já não existe. O timer
	// órfão JÁ MORDEU neste projeto, em `pacientes/+page.svelte:74`.
	onDestroy(() => clearTimeout(timer));

	function pick(p: AgendaPatient) {
		onPick(p);
		term = '';
		results = [];
		searched = false;
		clearTimeout(timer);
	}

	const sobrando = $derived(total > results.length);
</script>

<div class="relative">
	{#if selected.length}
		<div class="mb-1.5 flex flex-wrap gap-1.5">
			{#each selected as p (p.id)}
				<span
					class="inline-flex items-center gap-1.5 rounded-full border border-edge bg-surface-2 py-0.5 pl-0.5 pr-2 text-[12.5px]"
				>
					<span
						class="grid size-5 place-items-center rounded-full text-[9px] font-bold text-white"
						style="background:{avatarColor(p.cor_indice ?? 1)}"
					>
						{initials(p.nome)}
					</span>
					{p.nome}
					<button
						type="button"
						aria-label="Remover {p.nome}"
						onclick={() => onRemove(p.id)}
						class="grid size-4 place-items-center rounded-full text-faint hover:bg-edge hover:text-ink"
					>
						<X size={11} />
					</button>
				</span>
			{/each}
		</div>
	{/if}

	{#if multi || !selected.length}
		<div class="relative">
			<span class="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-faint">
				<Search size={14} />
			</span>
			<input
				role="combobox"
				aria-expanded={results.length > 0}
				aria-autocomplete="list"
				aria-controls="patient-picker-results"
				aria-label="Buscar paciente"
				type="text"
				value={term}
				oninput={(e) => onInput(e.currentTarget.value)}
				placeholder="Buscar por nome, CPF ou telefone…"
				class="h-[38px] w-full rounded-md border border-edge-strong bg-surface pl-8 pr-3 text-[13.5px] text-ink placeholder:text-faint"
			/>
		</div>
	{/if}

	{#if results.length}
		<ul
			id="patient-picker-results"
			class="mt-1 max-h-52 overflow-auto rounded-md border border-edge bg-surface shadow-pop"
		>
			{#each results as p (p.id)}
				<li>
					<button
						type="button"
						onclick={() => pick(p)}
						class="flex w-full items-center gap-2 px-2.5 py-1.5 text-left text-[13px] hover:bg-surface-2"
					>
						<span
							class="grid size-6 shrink-0 place-items-center rounded-full text-[9.5px] font-bold text-white"
							style="background:{avatarColor(p.cor_indice ?? 1)}"
						>
							{initials(p.nome)}
						</span>
						<span class="min-w-0 flex-1 truncate">{p.nome}</span>
						{#if p.tel}<span class="font-mono text-[11px] text-faint">{p.tel}</span>{/if}
					</button>
				</li>
			{/each}
		</ul>
		{#if sobrando}
			<div class="mt-1 text-[11.5px] text-faint">
				Mostrando {results.length} de {total} — refine a busca
			</div>
		{/if}
	{:else if searched}
		<div class="mt-1 text-[12px] text-faint">Nenhum paciente encontrado.</div>
	{/if}
</div>
