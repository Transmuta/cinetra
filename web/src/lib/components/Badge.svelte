<script lang="ts">
	// A pílula: um rótulo curto que qualifica o que está ao lado (papel, prioridade, estado).
	//
	// Havia três componentes de badge — `RoleBadge`, `StatusBadge`, `PriorityBadge` — em três
	// subpastas, **com três geometrias e base zero compartilhada**, mais ~16 grafias inline com o
	// mesmo papel (doc 93 §B-4). Cada uma escolhia o seu padding, o seu peso e o seu tamanho.
	//
	// O que este componente NÃO absorve, de propósito: o `StatusBadge`. Ele não é pílula — é um
	// ponto colorido seguido de texto, sem fundo. Forçá-lo aqui daria um componente com uma flag
	// booleana que troca a geometria inteira, que é exatamente o antipadrão que a base não tem em
	// lugar nenhum (doc 94 §2.5).
	import type { Snippet } from 'svelte';

	let {
		tone = 'neutro',
		size = 'sm',
		style = undefined,
		class: extra = '',
		children
	}: {
		tone?: 'accent' | 'neutro' | 'contorno' | 'success' | 'warning' | 'danger' | 'info';
		size?: 'sm' | 'md';
		/** Cor resolvida em runtime — a paleta de prioridade é hex fixo e não passa por token. */
		style?: string;
		class?: string;
		children: Snippet;
	} = $props();

	const sizes = {
		sm: 'gap-1 px-2 py-0.5 text-meta',
		md: 'gap-1.5 px-2.5 py-1 text-rotulo'
	} as const;

	// As semânticas usam a própria tinta a 14% como fundo — o mesmo par que o `contraste.test.ts`
	// mede, e a razão de `--mv-warning` e parentes serem mais escuros que o mínimo óbvio.
	const tones = {
		accent: 'bg-accent-subtle text-accent-text',
		neutro: 'bg-surface-2 text-muted',
		contorno: 'border border-edge bg-surface-2 text-muted',
		success: 'bg-success/14 text-success',
		warning: 'bg-warning/14 text-warning',
		danger: 'bg-danger/10 text-danger',
		info: 'bg-info/14 text-info'
	} as const;

	const classe = $derived(
		`inline-flex max-w-full items-center rounded-full font-semibold ${sizes[size]} ${tones[tone]} ${extra}`
	);
</script>

<span class={classe} {style}>{@render children()}</span>
