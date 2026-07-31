<script lang="ts">
	// **A3 / D12** — o `horarioConflitos` do protótipo (:1220), agora com dado do servidor.
	//
	// Aparece quando a API recusa uma mudança de horário com 409 `future_conflicts`. É um
	// **aviso**, não uma escolha: não existe "salvar mesmo assim". Mexer no expediente por cima de
	// agenda marcada não é uma opção do produto, então o modal serve para a recepção saber
	// exatamente o que remarcar — e voltar aqui quando tiver resolvido.
	//
	// A lista mostra os primeiros (o servidor detalha 10) e o rodapé diz o número **real**: numa
	// mudança que afeta 80 sessões, 80 linhas não ajudam ninguém a começar; "10 e mais 70" ajudam.
	import ExternalLink from '@lucide/svelte/icons/external-link';
	import Modal from '$lib/components/Modal.svelte';
	import { appointmentHref } from '$lib/agenda';
	import {
		diaCurto,
		motivoLabel,
		resumoConflitos,
		restoNaoListado,
		type FutureConflicts
	} from '$lib/scheduling-conflicts';

	let {
		conflitos,
		onClose
	}: {
		conflitos: FutureConflicts;
		onClose: () => void;
	} = $props();

	const resto = $derived(restoNaoListado(conflitos));
</script>

<Modal title="Conflitos com a agenda" {onClose} maxWidth="max-w-[520px]">
	<p class="mb-3 text-[13px] text-muted">
		{resumoConflitos(conflitos)}. Remarque ou cancele antes de aplicar a mudança.
	</p>

	<ul class="flex flex-col gap-1.5">
		{#each conflitos.conflicts as c (c.appointment_id)}
			<li class="rounded-lg border border-edge bg-surface-2 px-3 py-2">
				<div class="flex items-baseline gap-2">
					<span class="text-[13px] font-bold text-ink">{diaCurto(c.date)} · {c.hora}</span>
					{#if c.professional.nome}
						<span class="truncate text-[12.5px] text-muted">{c.professional.nome}</span>
					{/if}
					<span class="flex-1"></span>
					<!--
						O modal manda remarcar ou cancelar e, até aqui, não dava o caminho: a recepção
						anotava dia e hora e ia procurar na agenda (doc 85).

						**Em outra aba**, e é o único link do app assim: o 409 não salvou nada, então o
						formulário de horário atrás do modal ainda tem a edição inteira por aplicar. Sair
						desta aba jogaria fora o trabalho que o próprio modal está pedindo para viabilizar.
					-->
					<a
						href={appointmentHref(c.appointment_id, c.date)}
						target="_blank"
						rel="noopener"
						class="inline-flex shrink-0 items-center gap-1 text-[11.5px] font-semibold text-accent-text hover:underline"
						aria-label="Abrir {diaCurto(c.date)} às {c.hora} na agenda, em outra aba"
					>
						<ExternalLink size={12} /> Abrir
					</a>
				</div>

				{#if c.patients.length}
					<div class="truncate text-[12.5px] text-ink">{c.patients.join(', ')}</div>
				{/if}

				<div class="text-[11.5px] text-faint">{motivoLabel(c)}</div>
			</li>
		{/each}
	</ul>

	{#if resto}
		<p class="mt-2 text-[12px] font-semibold text-muted">{resto}</p>
	{/if}

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-lg bg-primary px-4 py-2 text-[13px] font-semibold text-on-primary hover:bg-primary-hover"
		>
			Entendi
		</button>
	{/snippet}
</Modal>
