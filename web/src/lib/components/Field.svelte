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
		children = undefined
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
		/** limites do input numérico (duração 10/5, capacidade 2 — protótipo :2396, :2402) */
		min?: number;
		step?: number;
		/** fonte mono: os números do protótipo (duração, capacidade, horários) usam Martian Mono */
		mono?: boolean;
		/** classe de largura do input, quando ele não deve ocupar a linha (ex.: w-[120px]) */
		width?: string;
		/** Conteúdo no lugar do input — o `el` arbitrário que o fld() do protótipo (:1933)
		    sempre aceitou. Renderiza um GRUPO rotulado, não um <label>: um label aponta para
		    um controle só, e estes grupos (cor, ícone) têm vários botões. */
		children?: Snippet;
	} = $props();
</script>

<!-- Campo do protótipo: fld() :1933 (label 12/600 muted) + inputStyle() :1934 (h38, r8, bd). -->
{#if children}
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
			class="h-[38px] rounded-md border border-edge-strong bg-surface px-[11px] text-[13.5px] text-ink placeholder:text-faint {width} {mono
				? 'font-mono'
				: ''}"
		/>
	</label>
{/if}
