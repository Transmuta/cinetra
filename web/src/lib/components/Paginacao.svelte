<script lang="ts">
	// O rodapé de paginação das listas.
	//
	// Estava escrito quatro vezes — `/pacientes`, `/fila`, `/notificacoes`, `/auditoria` — e a
	// prova de que era cópia, e não convergência, é que a classe do botão era **a mesma string de
	// 200 caracteres** (`const navBtn`) declarada nos quatro arquivos (doc 94 §D-2). As diferenças
	// entre as cópias eram só ruído acumulado: `mt-3` contra `mt-4`, um `px-1` a mais na fila.
	//
	// A exceção real vira prop: `/notificacoes` NÃO mostra o "X–Y de Z" porque a API do sino não
	// conta o total de propósito (contar obriga a ler o recorte inteiro — 10.265 buffers contra
	// 26, medido). Passar `rotulo={null}` diz isso em voz alta; antes era um bloco ausente que
	// parecia esquecimento.
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import type { PageInfo } from '$lib/pagination';

	let {
		current,
		pageInfo,
		onPage,
		rotulo = null,
		class: extra = ''
	}: {
		/** página atual, 1-based */
		current: number;
		pageInfo: PageInfo;
		onPage: (n: number) => void;
		/** "1–50 de 214". `null` quando a API não conta o total — ver a nota acima. */
		rotulo?: string | null;
		class?: string;
	} = $props();

	const primeira = $derived(current === 1);

	const navBtn =
		'inline-flex items-center gap-1 rounded-lg border border-edge bg-surface px-2.5 py-1.5 text-[12.5px] font-semibold text-ink hover:bg-surface-2 disabled:opacity-40 disabled:hover:bg-surface';
</script>

<!-- Só aparece quando há mais de uma página: uma lista curta não ganha cromo. -->
{#if pageInfo.more || current > 1}
	<nav class="mt-4 flex items-center gap-3 {extra}" aria-label="Paginação">
		{#if rotulo}
			<span class="font-mono text-[11.5px] text-faint">{rotulo}</span>
		{/if}
		<div class="flex-1"></div>
		<button type="button" class={navBtn} disabled={primeira} onclick={() => onPage(current - 1)}>
			<ChevronLeft size={14} /> Anterior
		</button>
		<button
			type="button"
			class={navBtn}
			disabled={!pageInfo.more}
			onclick={() => onPage(current + 1)}
		>
			Próxima <ChevronRight size={14} />
		</button>
	</nav>
{/if}
