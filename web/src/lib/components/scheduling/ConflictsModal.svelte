<script lang="ts">
	// **A3 / D12** — o `horarioConflitos` do protótipo (:1220), agora com dado do servidor.
	//
	// Aparece quando a API recusa uma mudança de horário com 409 `future_conflicts`. Lista o que
	// quebraria e dá duas saídas: voltar e ajustar a agenda, ou aplicar assim mesmo. O botão de
	// aplicar só existe **aqui** — ou seja, ninguém confirma sem ter visto a lista, que é a
	// diferença entre um gate e um popup de "tem certeza?".
	import Modal from '$lib/components/Modal.svelte';
	import {
		diaCurto,
		motivoLabel,
		resumoConflitos,
		type FutureConflicts
	} from '$lib/scheduling-conflicts';

	let {
		conflitos,
		onClose,
		onConfirm,
		confirmLabel = 'Salvar mesmo assim'
	}: {
		conflitos: FutureConflicts;
		onClose: () => void;
		/** Reenvia a mesma mudança com `confirm: true`. */
		onConfirm: () => void;
		confirmLabel?: string;
	} = $props();
</script>

<Modal title="Conflitos com a agenda" {onClose} maxWidth="max-w-[520px]">
	<p class="mb-3 text-[13px] text-muted">
		{resumoConflitos(conflitos)}. Remarque ou cancele antes de aplicar — ou aplique assim mesmo e
		resolva depois.
	</p>

	<ul class="flex flex-col gap-1.5">
		{#each conflitos.conflicts as c (c.appointment_id)}
			<li class="rounded-lg border border-edge bg-surface-2 px-3 py-2">
				<div class="flex items-baseline gap-2">
					<span class="text-[13px] font-bold text-ink">{diaCurto(c.date)} · {c.hora}</span>
					{#if c.professional.nome}
						<span class="truncate text-[12.5px] text-muted">{c.professional.nome}</span>
					{/if}
				</div>

				{#if c.patients.length}
					<div class="truncate text-[12.5px] text-ink">{c.patients.join(', ')}</div>
				{/if}

				<div class="text-[11.5px] text-faint">{motivoLabel(c)}</div>
			</li>
		{/each}
	</ul>

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-lg border border-edge bg-surface px-3.5 py-2 text-[13px] font-semibold text-muted hover:bg-surface-2"
		>
			Voltar e ajustar
		</button>

		<button
			type="button"
			onclick={onConfirm}
			class="rounded-lg bg-primary px-4 py-2 text-[13px] font-semibold text-on-primary hover:bg-primary-hover"
		>
			{confirmLabel}
		</button>
	{/snippet}
</Modal>
