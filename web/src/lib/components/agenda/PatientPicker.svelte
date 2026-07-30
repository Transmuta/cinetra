<script lang="ts">
	// Busca de paciente do modal (protótipo `patientField` :1941): ≥2 caracteres, no máximo
	// 10 resultados com o aviso "refine a busca".
	import { onDestroy } from 'svelte';
	import X from '@lucide/svelte/icons/x';
	import Search from '@lucide/svelte/icons/search';
	import { initials } from '$lib/format';
	import { formatarTelefone } from '$lib/telefone';
	import { avatarColor, avatarStyle } from '$lib/avatar';
	import { CONTROL_CLASS } from '$lib/components/Field.svelte';
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
			ativo = -1;
			return;
		}

		timer = setTimeout(async () => {
			const r = await search(value.trim());
			results = r.patients;
			total = r.total;
			searched = true;
			// Resultado novo, destaque zerado: manter o índice antigo apontaria para outra pessoa.
			ativo = -1;
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
		ativo = -1;
		clearTimeout(timer);
	}

	const sobrando = $derived(total > results.length);

	// ---- Teclado (ACC-21, doc 83) -----------------------------------------------------------
	//
	// O componente já se anunciava como `role="combobox"` e apontava `aria-controls` para a lista,
	// mas não tinha **nenhum** `onkeydown`: seta para baixo não navegava, e a lista não era
	// `listbox` nem os itens `option`. Prometia um padrão e entregava outro — pior que não
	// prometer, porque o leitor de tela instrui a pessoa a usar as setas.
	//
	// O foco NÃO se move para a lista (é o padrão ARIA 1.2 de combobox): ele fica no input e quem
	// diz onde está o destaque é o `aria-activedescendant`.

	/** Índice destacado na lista; -1 = nenhum. */
	let ativo = $state(-1);

	/** O `id` de cada option — é o que o `aria-activedescendant` referencia. */
	const idDaOpcao = (i: number) => `patient-picker-opt-${i}`;

	function aoTeclar(event: KeyboardEvent) {
		if (!results.length) return;

		switch (event.key) {
			case 'ArrowDown':
				event.preventDefault();
				ativo = (ativo + 1) % results.length;
				break;
			case 'ArrowUp':
				event.preventDefault();
				ativo = ativo <= 0 ? results.length - 1 : ativo - 1;
				break;
			case 'Home':
				event.preventDefault();
				ativo = 0;
				break;
			case 'End':
				event.preventDefault();
				ativo = results.length - 1;
				break;
			case 'Enter':
				// Sem destaque, Enter não escolhe por adivinhação — e não pode submeter o formulário
				// do modal com a lista aberta, então o `preventDefault` vale nos dois casos.
				event.preventDefault();
				if (ativo >= 0) pick(results[ativo]);
				break;
			case 'Escape':
				// Fecha a LISTA, não o modal. O shell do `Modal` escuta Esc na janela, então sem parar
				// a propagação aqui um Esc fecharia os dois de uma vez — o mesmo cuidado que o
				// `Drawer` já toma para o par drawer×modal.
				event.stopPropagation();
				results = [];
				searched = false;
				ativo = -1;
				break;
		}
	}
</script>

<div class="relative">
	{#if selected.length}
		<div class="mb-1.5 flex flex-wrap gap-1.5">
			{#each selected as p (p.id)}
				<span
					class="inline-flex items-center gap-1.5 rounded-full border border-edge bg-surface-2 py-0.5 pl-0.5 pr-2 text-[12.5px]"
				>
					<span
						class="grid size-5 place-items-center rounded-full text-[9px] font-bold"
						style={avatarStyle(p.cor_indice ?? 1)}
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
			<!-- Não é um `<Field>`: o rótulo vem de fora (o modal já embrulha o picker inteiro
			     num Field, porque o texto muda com o tipo — "Paciente" vs "Participantes (2/4)")
			     e o padding é assimétrico para abrir espaço ao ícone de lupa, coisa que o input
			     do Field não faz. O que NÃO se duplica é a lista de tokens: vem do CONTROL_CLASS. -->
			<input
				role="combobox"
				aria-expanded={results.length > 0}
				aria-autocomplete="list"
				aria-controls="patient-picker-results"
				aria-activedescendant={ativo >= 0 ? idDaOpcao(ativo) : undefined}
				aria-label="Buscar paciente"
				type="text"
				value={term}
				oninput={(e) => onInput(e.currentTarget.value)}
				onkeydown={aoTeclar}
				placeholder="Buscar por nome, CPF ou telefone…"
				class="h-[38px] w-full {CONTROL_CLASS} pl-8 pr-3"
			/>
		</div>
	{/if}

	{#if results.length}
		<!--
			`listbox` de `option`s, e não uma `<ul>` de botões (ACC-21). Duas razões:

			 * o input diz `role="combobox"` e aponta `aria-controls` para cá — sem `listbox` a
			   promessa não se cumpre e o leitor de tela instrui a usar setas que não funcionavam;
			 * `option` não pode ter descendente focável, e o `<button>` de antes era exatamente
			   isso: convivia com o `aria-activedescendant` disputando quem "está" selecionado.

			O clique continua funcionando; o teclado mora no input (`aoTeclar`), como manda o padrão.
		-->
		<ul
			id="patient-picker-results"
			role="listbox"
			aria-label="Pacientes encontrados"
			class="mt-1 max-h-52 overflow-auto rounded-md border border-edge bg-surface shadow-pop"
		>
			{#each results as p, i (p.id)}
				<!-- svelte-ignore a11y_click_events_have_key_events -->
				<li
					id={idDaOpcao(i)}
					role="option"
					aria-selected={i === ativo}
					onclick={() => pick(p)}
					class="flex w-full cursor-pointer items-center gap-2 px-2.5 py-1.5 text-left text-[13px] {i ===
					ativo
						? 'bg-surface-2'
						: 'hover:bg-surface-2'}"
				>
					<span
						class="grid size-6 shrink-0 place-items-center rounded-full text-[9.5px] font-bold"
						style={avatarStyle(p.cor_indice ?? 1)}
					>
						{initials(p.nome)}
					</span>
					<span class="min-w-0 flex-1 truncate">{p.nome}</span>
					{#if p.tel}<span class="font-mono text-[11px] text-faint">{formatarTelefone(p.tel)}</span>{/if}
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
