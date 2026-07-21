<script lang="ts">
	// A caixa de erro do 422 com a saída "Marcar como encaixe" — compartilhada por
	// NewAppointmentModal (criar) e RescheduleModal (remarcar), Entrega 4. As duas telas
	// recusam por conflito da mesma forma (A-D2b: o encaixe suprime o bloqueio, não a exibição),
	// e ter duas cópias faria a estética do 422-com-saída divergir entre criar e remarcar — o
	// mesmo motivo que levou a extrair `Field`/`Modal`/`mutate` no resto do projeto.
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';

	let {
		erro = undefined,
		ofereceEncaixe = false,
		onEncaixe
	}: {
		/** Mensagem do servidor; ausente = nada a mostrar. */
		erro?: string;
		/** Só quando o erro é conflito E quem vê pode marcar encaixe (D14: fora do expediente, não). */
		ofereceEncaixe?: boolean;
		onEncaixe: () => void;
	} = $props();
</script>

{#if erro}
	<div
		class="mt-2 flex items-start gap-2 rounded-lg px-3 py-2.5 text-[12.5px]"
		style="background:color-mix(in srgb, var(--color-danger) 10%, transparent); color:var(--color-danger)"
	>
		<TriangleAlert size={16} class="mt-0.5 shrink-0" />
		<div class="min-w-0">
			<div>{erro}</div>
			{#if ofereceEncaixe}
				<button
					type="button"
					onclick={onEncaixe}
					class="mt-1.5 rounded-md border border-current px-2 py-1 text-[12px] font-semibold"
				>
					Marcar como encaixe
				</button>
			{/if}
		</div>
	</div>
{/if}
