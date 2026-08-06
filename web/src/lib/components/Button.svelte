<script lang="ts">
	// O botão do app.
	//
	// Ele existia e era usado **uma vez** (doc 93 §M-5), e a causa era diagnosticável numa linha:
	// nascia `flex w-full`, ou seja, era o botão de largura total das telas de AUTH, não o botão
	// do app. Como o app quase nunca quer largura total, o componente ficou inutilizável e cada
	// tela rolou a sua — 23 instâncias primárias em 15 grafias, variando padding, fonte, hover
	// (quatro sem nenhum) e tratamento de desabilitado (doc 93 §M-4).
	//
	// O que mudou: a largura saiu do componente. `w-full` agora é `class` do CHAMADOR, o único
	// que sabe se aquele botão preenche a linha — e é o que as telas de auth passam.
	//
	// **`emVoo` vem junto de propósito.** Era o `SubmitButton` que cuidava disso, e ele resolvia o
	// eixo certo: travar durante o envio, anunciar `aria-busy` e MOSTRAR o giro (um botão só
	// apagado parece quebrado e convida ao segundo clique). Mas ele explicitamente não impõe
	// visual — então o app tinha um componente que cuidava do comportamento e nenhum que cuidasse
	// da aparência. Aqui os dois moram juntos para o caso comum; o `SubmitButton` continua
	// existindo para os botões de visual próprio (só-ícone, linha de tabela, chip).
	import type { Snippet } from 'svelte';
	import Loader from '@lucide/svelte/icons/loader-circle';

	let {
		variant = 'primary',
		size = 'md',
		type = 'button',
		href = undefined,
		reload = false,
		emVoo = false,
		disabled = false,
		form = undefined,
		title = undefined,
		ariaLabel = undefined,
		name = undefined,
		value = undefined,
		class: extra = '',
		onclick = undefined,
		children
	}: {
		variant?: 'primary' | 'secondary' | 'ghost' | 'danger';
		size?: 'sm' | 'md';
		type?: 'button' | 'submit';
		href?: string;
		/** Força navegação completa (`data-sveltekit-reload`). Necessário para link a `+server`,
		    que não tem `+page` e 404a se o roteador do cliente tentar resolvê-lo como página. */
		reload?: boolean;
		/** POST em voo: trava o clique, anuncia `aria-busy` e mostra o giro. */
		emVoo?: boolean;
		disabled?: boolean;
		form?: string;
		title?: string;
		ariaLabel?: string;
		name?: string;
		value?: string;
		/** Só o que é do CHAMADOR: largura, alinhamento, animação de entrada. */
		class?: string;
		onclick?: (event: MouseEvent) => void;
		children: Snippet;
	} = $props();

	const base =
		'inline-flex items-center justify-center gap-1.5 rounded-controle font-semibold transition-colors disabled:cursor-not-allowed disabled:opacity-60';

	const sizes = {
		sm: 'px-3 py-1.5 text-rotulo',
		md: 'px-3.5 py-2 text-corpo'
	} as const;

	// `danger` leva branco fixo sobre o vermelho ESCURECIDO (`--mv-danger-solid`): texto escuro
	// sobre vermelho claro perde a força de aviso, e o token foi escurecido justamente para o
	// branco passar em 4,55 (ver a nota no `app.css`).
	const variants = {
		primary: 'bg-primary text-on-primary hover:bg-primary-hover',
		secondary: 'border border-edge bg-surface text-ink hover:bg-surface-2',
		ghost: 'text-muted hover:bg-surface-2 hover:text-ink',
		danger: 'bg-danger-solid text-white hover:opacity-90'
	} as const;

	const classe = $derived(`${base} ${sizes[size]} ${variants[variant]} ${extra}`);
</script>

{#if href}
	<a
		{href}
		{onclick}
		{title}
		data-sveltekit-reload={reload ? '' : undefined}
		aria-label={ariaLabel}
		aria-busy={emVoo || undefined}
		class="{classe} {emVoo ? 'pointer-events-none opacity-70' : ''}"
	>
		{#if emVoo}<Loader size={14} class="animate-spin" />{/if}
		{@render children()}
	</a>
{:else}
	<button
		{type}
		{form}
		{title}
		{name}
		{value}
		{onclick}
		aria-label={ariaLabel}
		aria-busy={emVoo}
		disabled={disabled || emVoo}
		class={classe}
	>
		{#if emVoo}<Loader size={14} class="animate-spin" />{/if}
		{@render children()}
	</button>
{/if}
