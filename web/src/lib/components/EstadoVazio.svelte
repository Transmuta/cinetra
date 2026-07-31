<script lang="ts">
	// "Não há nada aqui" — ícone, o que está vazio, e o que fazer a respeito.
	//
	// O papel estava escrito **cinco vezes com cinco geometrias** (doc 94 §2.4): painel com borda
	// em `/auditoria` e `/notificacoes`, `p-12` sem borda no `ListView`, `px-4 py-7` no
	// `OfferSlotModal`, e `h-full bg-canvas` no `AgendaEmptyState` — com o título ora em 14px, ora
	// em 13,5, e o ícone ora 26, ora 28.
	//
	// A lição que o `AgendaEmptyState` já tinha registrado, e que vale para todos: **um vazio que
	// não diz QUAL vazio mente**. Lá, cada visão degradava para uma frase falsa diferente ("Sem
	// expediente" quando a clínica abre, "Nenhum agendamento" havendo agendamentos filtrados).
	// Por isso `titulo` e `descricao` são obrigatoriamente do chamador: não há texto padrão que
	// sirva, e um padrão genérico seria justamente a frase falsa.
	//
	// `descricao` é Snippet, e não string, porque três dos cinco casos têm marcação dentro — um
	// botão "limpar os filtros" no meio da frase, uma ênfase, um nome de menu entre aspas.
	import type { Component, Snippet } from 'svelte';

	let {
		icone: Icone,
		titulo,
		descricao,
		acao,
		variante = 'painel',
		class: extra = ''
	}: {
		icone: Component<{ size?: number; class?: string }>;
		titulo: string;
		descricao?: Snippet;
		/** Botão ou link de saída. Sem ele o vazio é só constatação. */
		acao?: Snippet;
		/** `painel` = cartão com borda, para o vazio de uma TELA. `inline` = sem casca, para o
		    vazio dentro de um cartão ou modal que já tem a sua. */
		variante?: 'painel' | 'inline';
		class?: string;
	} = $props();

	const casca = $derived(
		variante === 'painel' ? 'rounded-xl border border-edge bg-surface px-6 py-16' : 'p-8'
	);
</script>

<div class="flex flex-col items-center justify-center gap-2 text-center {casca} {extra}">
	<Icone size={28} class="text-faint" />

	<p class="text-[13.5px] font-semibold text-ink">{titulo}</p>

	{#if descricao}
		<p class="max-w-[380px] text-[12.5px] text-muted">{@render descricao()}</p>
	{/if}

	{#if acao}
		<div class="mt-1">{@render acao()}</div>
	{/if}
</div>
