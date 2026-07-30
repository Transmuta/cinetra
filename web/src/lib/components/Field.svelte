<script module lang="ts">
	// Tokens do controle (protótipo `inputStyle()` :1934), SEM altura e SEM padding
	// horizontal — cada controle decide os seus (o textarea cresce, o campo de busca abre
	// espaço para o ícone). Exportado porque `<select>`/`<textarea>` não são renderizados
	// por este componente: sem uma constante, cada modal reescrevia a lista à mão e ela
	// divergiu — a agenda tinha `px-2.5` (10px) e perdeu `text-ink`/`placeholder:text-faint`.
	export const CONTROL_CLASS =
		'rounded-md border border-edge-strong bg-surface text-[13.5px] text-ink placeholder:text-faint';
	/** Padding horizontal padrão do controle. */
	export const CONTROL_PX = 'px-[11px]';
</script>

<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { HTMLInputAttributes } from 'svelte/elements';

	let {
		label,
		name = undefined,
		type = 'text',
		value = $bindable(''),
		placeholder = '',
		required = false,
		autocomplete = undefined,
		maxlength = undefined,
		min = undefined,
		step = undefined,
		mono = false,
		width = 'w-full',
		children = undefined,
		control = undefined
	}: {
		label: string;
		name?: string;
		type?: HTMLInputAttributes['type'];
		/** Texto do input. Num campo `type="number"` o binding do Svelte devolve number — por
		    isso os numéricos aqui só recebem o valor INICIAL, sem `bind:` de volta. */
		value?: string;
		placeholder?: string;
		required?: boolean;
		autocomplete?: HTMLInputAttributes['autocomplete'];
		maxlength?: number;
		/** Piso do input: número (duração 10/5, capacidade 2 — protótipo :2396, :2402) ou **data**
		    `AAAA-MM-DD` num `type="date"` — é assim que o HTML barra o passado no seletor nativo. */
		min?: number | string;
		step?: number;
		/** fonte mono: os números do protótipo (duração, capacidade, horários) usam Martian Mono */
		mono?: boolean;
		/** classe de largura do input, quando ele não deve ocupar a linha (ex.: w-[120px]) */
		width?: string;
		/** Conteúdo no lugar do input — o `el` arbitrário que o fld() do protótipo (:1933)
		    sempre aceitou. Renderiza um GRUPO rotulado, não um <label>: um label aponta para
		    um controle só, e estes grupos (cor, ícone) têm vários botões. */
		children?: Snippet;
		/** Controle próprio (`<select>`, `<textarea>`) DENTRO do <label>, para reusar o rótulo
		    sem perder a associação. O slot `children` renderiza um `role="group"`, correto para
		    grupos de botões (cor, ícone) e ERRADO para um controle único: o select ficaria sem
		    nome acessível. */
		control?: Snippet;
	} = $props();
</script>

<!-- Campo do protótipo: fld() :1933 (label 12/600 muted) + inputStyle() :1934 (h38, r8, bd). -->
{#if control}
	<label class="mb-3 block min-w-0">
		<span class="mb-[5px] block text-[12px] font-semibold text-muted">{label}</span>
		{@render control()}
	</label>
{:else if children}
	<div class="mb-3 min-w-0" role="group" aria-label={label}>
		<span class="mb-[5px] block text-[12px] font-semibold text-muted">{label}</span>
		{@render children()}
	</div>
{:else}
	<label class="mb-3 block min-w-0">
		<span class="mb-[5px] block text-[12px] font-semibold text-muted">{label}</span>
		<input
			{name}
			{type}
			{placeholder}
			{required}
			{autocomplete}
			{maxlength}
			{min}
			{step}
			bind:value
			class="h-[38px] {CONTROL_CLASS} {CONTROL_PX} {width} {mono ? 'font-mono' : ''}"
		/>
	</label>
{/if}
