<script lang="ts">
	// Pill do protótipo (renderToast :3491): flutua no bottom-center, pintada com os tokens
	// primary/on-primary e com sombra própria. Quem decide o que mostrar e por quanto tempo
	// é $lib/toast.svelte.ts.
	//
	// Antes da ADR-020 esse par era o do tema INVERTIDO (#16181c/#fff no claro, #eceef0/#16181c
	// no escuro), e a inversão é que dava o contraste. Hoje `primary` é o sage da marca, igual
	// nos dois temas: a pill não inverte mais — no tema escuro ela deixou de ser quase-branca.
	//
	// O ícone distingue a variante pela FORMA — check para sucesso, alerta para erro (o protótipo
	// não distinguia, e por isso um "Dados inválidos" saía com o check verde de sucesso).
	//
	// A forma carrega isso sozinha porque a COR não pode mais: o antigo teal do check media 1,06:1
	// sobre o sage de `primary` (quase a mesma luminância — o check sumia) e o danger, 1,20–2,13.
	// Os dois passaram a `text-on-primary`, o mesmo branco do texto da pill. Cor nunca foi o
	// único sinal aqui, então nada se perde em 1.4.1.
	import Check from '@lucide/svelte/icons/check';
	import CircleAlert from '@lucide/svelte/icons/circle-alert';
	import { currentToast } from '$lib/toast.svelte';

	const active = $derived(currentToast());
</script>

<!--
	A região de status é SEMPRE montada, e vazia enquanto não há toast (ACC-05, doc 83).

	Antes o `{#if}` embrulhava o próprio `role="status"`: região e conteúdo nasciam no mesmo
	instante, e uma live region que já aparece preenchida tipicamente **não é anunciada** — o
	leitor de tela precisa observar a mudança dentro de uma região que já existia. Como este toast
	é o feedback de salvar/excluir/arquivar de todo o app, o efeito prático era que quase nenhuma
	confirmação de ação chegava a quem não vê a tela.

	O wrapper centraliza; o pill é quem anima (mvFade mexe em transform, e animar o próprio
	elemento centralizado por translateX faria o pill pular no fim).
-->
<div
	role="status"
	aria-live="polite"
	aria-atomic="true"
	class="pointer-events-none fixed inset-x-0 bottom-5.5 z-toast flex justify-center px-4"
>
	{#if active}
		<div
			class="flex animate-fade items-center gap-2 rounded-cartao bg-primary px-4 py-2.5 text-corpo font-semibold text-on-primary shadow-toast"
		>
			{#if active.variant === 'error'}
				<CircleAlert size={15} class="shrink-0 text-on-primary" />
			{:else}
				<Check size={15} class="shrink-0 text-on-primary" />
			{/if}
			{active.message}
		</div>
	{/if}
</div>
