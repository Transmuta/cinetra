<script lang="ts">
	// Confirmação destrutiva no molde do modalPkgCancelar do protótipo (:680): painel
	// de 440px cujo corpo é um callout de perigo (fundo/borda danger translúcidos +
	// TriangleAlert) e rodapé "Voltar" (btnS) + ação sólida em danger (btnP vermelho).
	import type { Snippet } from 'svelte';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Loader from '@lucide/svelte/icons/loader-circle';
	import Modal from './Modal.svelte';

	let {
		title,
		confirmLabel,
		cancelLabel = 'Voltar',
		submitting = false,
		onConfirm,
		onClose,
		children
	}: {
		title: string;
		confirmLabel: string;
		cancelLabel?: string;
		/** trava a ação enquanto o POST está em voo */
		submitting?: boolean;
		onConfirm: () => void;
		onClose: () => void;
		/** a pergunta/consequência, com marcação livre (nomes em <strong> etc.) */
		children: Snippet;
	} = $props();
</script>

<Modal {title} {onClose}>
	<div
		class="flex items-start gap-2.75 rounded-[11px] border border-danger/30 bg-danger/10 px-3.25 py-3"
	>
		<TriangleAlert size={18} class="mt-px shrink-0 text-danger" />
		<div class="text-[13px] leading-normal text-ink">{@render children()}</div>
	</div>

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-md border border-edge bg-surface px-4 py-2.25 text-[13.5px] font-semibold text-ink hover:bg-surface-2"
		>
			{cancelLabel}
		</button>
		<!-- O `disabled` sozinho não é feedback: numa ação destrutiva que leva um segundo, o botão
		     apagado parece quebrado e a pessoa clica de novo. O giro diz "está indo". -->
		<button
			type="button"
			onclick={onConfirm}
			disabled={submitting}
			aria-busy={submitting}
			class="inline-flex items-center gap-1.5 rounded-md bg-danger-solid px-4 py-2.25 text-[13.5px] font-bold text-white hover:opacity-90 disabled:opacity-60"
		>
			{#if submitting}<Loader size={14} class="animate-spin" />{/if}
			{confirmLabel}
		</button>
	{/snippet}
</Modal>
