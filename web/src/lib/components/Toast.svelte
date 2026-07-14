<script lang="ts">
	// Pill do protótipo (renderToast :3491): flutua no bottom-center, cores do tema
	// INVERTIDAS — que são exatamente os tokens primary/on-primary (#16181c/#fff no
	// claro, #eceef0/#16181c no escuro) — com Check teal fixo e sombra própria.
	// Quem decide o que mostrar e por quanto tempo é $lib/toast.svelte.ts.
	import Check from '@lucide/svelte/icons/check';
	import { currentToast } from '$lib/toast.svelte';
</script>

{#if currentToast()}
	<!-- o wrapper centraliza; o pill é quem anima (mvFade mexe em transform, e animar
	     o próprio elemento centralizado por translateX faria o pill pular no fim) -->
	<div class="pointer-events-none fixed inset-x-0 bottom-5.5 z-[60] flex justify-center px-4">
		<div
			role="status"
			class="flex animate-fade items-center gap-2 rounded-[10px] bg-primary px-4 py-2.5 text-[13px] font-semibold text-on-primary shadow-toast"
		>
			<Check size={15} class="shrink-0 text-teal" />
			{currentToast()}
		</div>
	</div>
{/if}
