<script lang="ts">
	// "Ajustar sessões futuras" (doc 41 etapa 3/4, contrato 09 §3.1.1 ponto 3) — a massa por pacote
	// vista do cartão da ficha.
	//
	// Duas decisões que a tela materializa:
	//
	//  - **o escopo é `todas`**, e não é escolha do usuário aqui: `esta`/`proximas` precisam de uma
	//    sessão de REFERÊNCIA, que só existe olhando a agenda. Oferecer os três no cartão pediria ao
	//    usuário um "qual é esta?" que a ficha não sabe responder;
	//  - **o alvo é a presença, não o bloco**: numa turma, mexer aqui move só a sessão deste
	//    paciente. É a correção que o contrato cobrou do `applyMassaPacote` do protótipo, e o texto
	//    do modal diz isso — senão a recepção acha que está remarcando a turma inteira.
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Modal from '$lib/components/Modal.svelte';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envio as criarEnvio } from '$lib/forms.svelte';
	import Field, { CONTROL_CLASS, CONTROL_PX } from '$lib/components/Field.svelte';
	import type { Package as Pkg } from '$lib/packages';

	type Prof = { id: string; nome: string };

	let {
		pkg,
		professionals,
		erro = undefined,
		onClose
	}: {
		pkg: Pkg;
		professionals: Prof[];
		/** erro da última tentativa (conflito de horário, por exemplo) */
		erro?: string;
		onClose: () => void;
	} = $props();

	let mudarProf = $state(false);
	let mudarHora = $state(false);
	// O modal remonta a cada abertura (`{#if ajustando}`), então o valor inicial vem da grade do
	// pacote UMA vez e passa a ser do usuário — o `untrack` torna a captura explícita (mesmo padrão
	// do `PackageCreateModal`).
	let profId = $state(untrack(() => pkg.grade?.professional_id ?? professionals[0]?.id ?? ''));
	let hhmm = $state('');

	// Sem nada marcado não há o que aplicar — o servidor recusa com `nada_a_aplicar`, e deixar o
	// botão vivo só para receber 422 é ruído.
	// Massa mexe em TODAS as sessões futuras do pacote — a ação mais cara da ficha, e a que mais
	// paga por um segundo clique. `reset: false`: o 409 volta com a prévia dentro do modal.
	const envio = criarEnvio({ reset: false });

	const podeAplicar = $derived((mudarProf && !!profId) || (mudarHora && !!hhmm));

	// O "aplicar mesmo assim" só aparece DEPOIS de um conflito, como na criação da série: é a
	// mesma decisão (encaixe) e o mesmo idioma.
	let forcar = $state(false);
	let form = $state<HTMLFormElement>();
</script>

<Modal title="Ajustar sessões futuras" {onClose} maxWidth="max-w-[520px]">
	<form
		method="POST"
		action="?/bulkAdjustPackage"
		bind:this={form}
		use:enhance={envio.submit}
		class="flex flex-col gap-3.5"
		id="bulk-adjust-form"
	>
		<input type="hidden" name="package_id" value={pkg.id} />
		<input type="hidden" name="forcar" value={String(forcar)} />

		<p class="text-[12.5px] text-muted">
			Vale para as sessões de <strong>{pkg.nome}</strong> que ainda vão acontecer. Numa turma, só a
			presença deste paciente se move — os outros participantes ficam onde estão.
		</p>

		<label class="flex items-center gap-2.5 text-[13px]">
			<input type="checkbox" bind:checked={mudarProf} class="size-4 accent-[var(--color-primary)]" />
			<span class="font-semibold">Mudar o profissional</span>
		</label>

		{#if mudarProf}
			<Field label="Profissional">
				{#snippet control()}
					<select
						name="professional_id"
						bind:value={profId}
						class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}"
					>
						{#each professionals as prof (prof.id)}
							<option value={prof.id}>{prof.nome}</option>
						{/each}
					</select>
				{/snippet}
			</Field>
		{/if}

		<label class="flex items-center gap-2.5 text-[13px]">
			<input type="checkbox" bind:checked={mudarHora} class="size-4 accent-[var(--color-primary)]" />
			<span class="font-semibold">Mudar o horário</span>
		</label>

		{#if mudarHora}
			<Field label="Horário (a data de cada sessão não muda)">
				{#snippet control()}
					<input
						type="time"
						name="hhmm"
						bind:value={hhmm}
						class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}"
					/>
				{/snippet}
			</Field>
		{/if}

		{#if erro}
			<div
				class="flex items-start gap-2 rounded-lg px-3 py-2.5 text-[12.5px]"
				style="background:color-mix(in srgb, var(--color-danger) 10%, transparent); color:var(--color-danger)"
			>
				<TriangleAlert size={16} class="mt-0.5 shrink-0" />
				<div>
					{erro}
					<!-- Nada é aplicado pela metade: a massa inteira volta atrás quando uma sessão
					     conflita (é uma transação só no servidor). Por isso a saída é reenviar tudo
					     como encaixe, e não "pular as que deram problema". -->
					<label class="mt-2 flex items-center gap-2 font-semibold">
						<input
							type="checkbox"
							bind:checked={forcar}
							class="size-4 accent-[var(--color-primary)]"
						/>
						Aplicar mesmo assim (marca como encaixe)
					</label>
				</div>
			</div>
		{/if}
	</form>

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-lg border border-edge px-3.5 py-2 text-[13px] font-semibold hover:bg-surface-2"
		>
			Voltar
		</button>
		<SubmitButton
			emVoo={envio.emVoo}
			form="bulk-adjust-form"
			disabled={!podeAplicar}
			class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary disabled:cursor-not-allowed disabled:opacity-50"
		>
			<CalendarClock size={15} /> Aplicar
		</SubmitButton>
	{/snippet}
</Modal>
