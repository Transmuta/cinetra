<script lang="ts">
	// O cromo dos formulários de cadastro: cabeçalho com avatar e progresso X/Y, coluna "SEÇÕES"
	// com scroll-spy, a área que rola, e o rodapé fixo com aviso + cancelar + salvar.
	//
	// `PatientForm` (823 linhas) e `ProfessionalForm` (754) eram gêmeos (doc 94 §D-1), e a prova
	// mais direta é que **a linha 3 dos dois era o mesmo comentário**. Compartilhavam o esqueleto
	// inteiro — `SECTIONS`, `totalKeys`, o laço da coluna, `goSec`, o `cardHead`, o `inputCls` —
	// e o custo já tinha sido cobrado: a divergência de token de campo (doc 93 §M-3) entrou DUAS
	// vezes, porque o arquivo foi copiado antes de o `Field` existir e depois não havia um lugar
	// só para consertar.
	//
	// O que fica no chamador é o que é dele: os cartões (`children`), a tabela de seções e as
	// contagens. Um terceiro cadastro — convênio, unidade — passa a ser barato em vez de uma
	// terceira cópia.
	//
	// O `active` mora AQUI, e não no chamador, porque quem tem o elemento que rola é este
	// componente. A decisão de qual seção está corrente é pura e vem de `$lib/form-secoes`.
	import { untrack, type Component, type Snippet } from 'svelte';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Button from '$lib/components/Button.svelte';
	import { initials } from '$lib/format';
	import { avatarStyle } from '$lib/avatar';
	import { secaoCorrente, totalDeChaves, totalPreenchido } from '$lib/form-secoes';

	export interface SecaoDaFicha {
		id: string;
		icon: Component<{ size?: number }>;
		/** Título, na coluna e no cartão. */
		t: string;
		/** Subtítulo do cartão — é o texto ÚNICO da seção (o título repete na coluna). */
		sub: string;
		/** Quantos campos a seção tem, para o X/Y. */
		total: number;
	}

	let {
		voltarHref,
		titulo,
		subtitulo,
		nome,
		corIndice,
		secoes,
		counts,
		problema = null,
		dica,
		acaoRotulo,
		acaoDesabilitada = false,
		emVoo = false,
		children
	}: {
		voltarHref: string;
		/** O nome digitado ganha do título — a ficha diz de quem ela é assim que se sabe. */
		titulo: string;
		subtitulo: string;
		nome: string;
		corIndice: number;
		secoes: readonly SecaoDaFicha[];
		counts: Record<string, number>;
		/** O que está errado AGORA, em uma frase. Anunciado e visível em qualquer largura. */
		problema?: string | null;
		/** O mínimo do formulário. Silenciosa e só no desktop — ver a nota no rodapé. */
		dica: string;
		acaoRotulo: string;
		acaoDesabilitada?: boolean;
		emVoo?: boolean;
		children: Snippet;
	} = $props();

	const totalKeys = $derived(totalDeChaves(secoes));
	const totalFilled = $derived(totalPreenchido(counts));

	// Semeia com a primeira seção e depois é independente — a lista não muda durante a vida do
	// componente (a ficha remonta a cada navegação). `untrack` é o idiom do repo para isso.
	let ativa = $state(untrack(() => secoes[0]?.id ?? ''));
	let areaQueRola = $state<HTMLElement | null>(null);

	function aoRolar() {
		if (!areaQueRola) return;
		const topoDoContainer = areaQueRola.getBoundingClientRect().top;
		const topos = secoes.flatMap((s) => {
			const el = document.getElementById(`sec-${s.id}`);
			return el
				? [{ id: s.id, topoRelativo: el.getBoundingClientRect().top - topoDoContainer }]
				: [];
		});
		ativa = secaoCorrente(topos, 56, secoes[0]?.id ?? '');
	}

	function irPara(id: string) {
		document.getElementById(`sec-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
	}
</script>

<!-- Cabeçalho do painel -->
<header class="flex shrink-0 items-center gap-3.5 border-b border-edge bg-surface px-4 py-3 md:px-6">
	<a
		href={voltarHref}
		title="Voltar"
		class="grid size-8.5 shrink-0 place-items-center rounded-controle border border-edge bg-surface text-muted hover:bg-surface-2"
	>
		<ChevronLeft size={18} />
	</a>
	<span
		class="grid size-10.5 shrink-0 place-items-center rounded-full text-titulo font-bold"
		style={avatarStyle(corIndice)}
	>
		{nome.trim() ? initials(nome) : '?'}
	</span>
	<div class="min-w-0 flex-1">
		<div class="truncate text-titulo font-bold md:text-destaque">{nome.trim() || titulo}</div>
		<div class="text-rotulo text-faint">{subtitulo}</div>
	</div>
	<div class="hidden shrink-0 items-center gap-2.5 md:flex">
		<div class="h-1.5 w-30 overflow-hidden rounded-micro bg-surface-2">
			<div
				class="h-full bg-accent transition-all"
				style="width:{totalKeys ? (totalFilled / totalKeys) * 100 : 0}%"
			></div>
		</div>
		<span class="font-mono text-meta text-faint">{totalFilled}/{totalKeys}</span>
	</div>
</header>

<div class="flex min-h-0 flex-1">
	<!-- SEÇÕES (desktop) -->
	<nav
		class="hidden w-59 shrink-0 overflow-y-auto border-r border-edge bg-surface p-3 md:block"
		aria-label="Seções do cadastro"
	>
		<div class="px-2 pb-2 text-micro font-bold text-faint">SEÇÕES</div>
		<div class="flex flex-col gap-0.5">
			{#each secoes as s (s.id)}
				{@const on = ativa === s.id}
				<button
					type="button"
					onclick={() => irPara(s.id)}
					aria-current={on ? 'true' : undefined}
					class="flex items-center gap-2.5 rounded-controle px-2.5 py-2 text-left text-corpo {on
						? 'bg-accent-subtle font-bold text-accent-text'
						: 'font-medium text-muted hover:bg-surface-2'}"
				>
					<s.icon size={16} />
					<span class="min-w-0 flex-1 truncate">{s.t}</span>
					{#if counts[s.id]}<span class="size-1.75 shrink-0 rounded-full bg-accent"></span>{/if}
				</button>
			{/each}
		</div>
	</nav>

	<!-- Cartões -->
	<div
		bind:this={areaQueRola}
		onscroll={aoRolar}
		class="min-h-0 flex-1 overflow-y-auto p-4 md:p-6"
	>
		<div class="mx-auto max-w-180 space-y-3.5 pb-4">
			{@render children()}
		</div>
	</div>
</div>

<!-- Rodapé fixo -->
<footer class="flex shrink-0 items-center gap-3 border-t border-edge bg-surface px-4 py-3 md:px-6">
	<!-- ACC-04 (doc 83): problema é `role="alert"` e visível em QUALQUER largura; dica segue só no
	     desktop e sem papel — se fosse alert, o leitor de tela a anunciaria a cada toque. -->
	{#if problema}
		<span role="alert" class="flex flex-1 items-center gap-1.5 text-rotulo text-danger">
			<TriangleAlert size={14} class="shrink-0" /> {problema}
		</span>
	{:else}
		<span class="hidden flex-1 items-center gap-1.5 text-rotulo text-faint md:flex">{dica}</span>
		<div class="flex-1 md:hidden"></div>
	{/if}

	<Button href={voltarHref} variant="secondary">Cancelar</Button>
	<Button type="submit" {emVoo} disabled={acaoDesabilitada}>{acaoRotulo}</Button>
</footer>
