<script lang="ts">
	// "Ajustar grade do pacote" (contrato 09:441, `modalAjustarGrade` do protótipo
	// [`:664`](../../../../interface/Movimento.dc.html#L664)).
	//
	// O que ele muda e o que **não** muda é a coisa mais importante da tela: vale para as sessões
	// que ainda vão acontecer — as já concluídas não se tocam, e `usadas` não muda. Trocar dia,
	// horário ou profissional **remarca** o horário do paciente na agenda.
	//
	// Diferente da massa (`PackageBulkModal`), que move profissional/horário sem mexer nos DIAS:
	// aqui a grade inteira é reescrita e a série futura é reprojetada a partir de hoje.
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import Info from '@lucide/svelte/icons/info';
	import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Modal from '$lib/components/Modal.svelte';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import Field, { CONTROL_CLASS, CONTROL_PX } from '$lib/components/Field.svelte';
	import { envio as criarEnvio } from '$lib/forms.svelte';
	import { DOW_LABELS, type Package as Pkg } from '$lib/packages';

	let {
		pkg,
		professionals,
		erro = undefined,
		onClose
	}: {
		pkg: Pkg;
		professionals: { id: string; nome: string }[];
		erro?: string;
		onClose: () => void;
	} = $props();

	// Parte da grade ATUAL e passa a ser do usuário — o modal remonta a cada abertura (`{#if
	// ajustandoGrade}`), então capturar o valor inicial é intencional; o `untrack` diz isso ao
	// compilador e cala o aviso de "referência só ao valor inicial" (mesmo padrão do
	// `PackageCreateModal`).
	let dows = $state<number[]>(untrack(() => [...(pkg.grade?.dows ?? [])].sort((a, b) => a - b)));
	let horarios = $state<Record<number, string>>(
		untrack(
			() =>
				Object.fromEntries(
					Object.entries(pkg.grade?.horarios ?? {}).map(([d, h]) => [Number(d), h])
				) as Record<number, string>
		)
	);
	let profId = $state(untrack(() => pkg.grade?.professional_id ?? professionals[0]?.id ?? ''));

	const envio = criarEnvio({ reset: false });

	function toggleDow(d: number) {
		if (dows.includes(d)) {
			dows = dows.filter((x) => x !== d);
		} else {
			dows = [...dows, d].sort((a, b) => a - b);
			if (!horarios[d]) horarios = { ...horarios, [d]: '08:00' };
		}
	}

	const podeSalvar = $derived(dows.length > 0 && dows.every((d) => !!horarios[d]) && !!profId);

	// O form manda plano (`dows=1,3` e `horarios=1=08:00,3=09:00`) e o BFF remonta o objeto: é um
	// `<form>` de verdade, não um fetch, então o `enhance` e o "está indo" saem de graça.
	const dowsPlano = $derived(dows.join(','));
	const horariosPlano = $derived(dows.map((d) => `${d}=${horarios[d]}`).join(','));
</script>

<Modal title="Ajustar grade do pacote" {onClose} maxWidth="max-w-[460px]">
	<form
		method="POST"
		action="?/adjustPackageGrade"
		id="grade-form"
		use:enhance={envio.submit}
		class="flex flex-col"
	>
		<input type="hidden" name="package_id" value={pkg.id} />
		<input type="hidden" name="dows" value={dowsPlano} />
		<input type="hidden" name="horarios" value={horariosPlano} />

		<div class="mb-3.5 flex items-start gap-2 rounded-[10px] bg-teal-subtle px-3 py-2.5 text-[12px] text-teal-text">
			<Info size={15} class="mt-0.5 shrink-0" />
			<span>
				Vale para as <strong>próximas</strong> sessões deste pacote. As já concluídas não mudam.
				Trocar dia, horário ou profissional <strong>remarca</strong> o horário do paciente na agenda.
			</span>
		</div>

		<Field label="Profissional">
			{#snippet control()}
				<select
					name="professional_id"
					bind:value={profId}
					class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}"
				>
					{#each professionals as p (p.id)}
						<option value={p.id}>{p.nome}</option>
					{/each}
				</select>
			{/snippet}
		</Field>

		<div class="mb-3" role="group" aria-label="Dias da semana">
			<span class="mb-[5px] block text-[12px] font-semibold text-muted">Dias da semana</span>
			<div class="flex flex-wrap gap-1.5">
				{#each DOW_LABELS as label, d (d)}
					<button
						type="button"
						onclick={() => toggleDow(d)}
						aria-pressed={dows.includes(d)}
						class="rounded-[8px] border px-2.5 py-1.5 text-[12.5px] font-semibold {dows.includes(d)
							? 'border-primary bg-primary text-on-primary'
							: 'border-edge bg-surface text-muted hover:bg-surface-2'}"
					>
						{label}
					</button>
				{/each}
			</div>
		</div>

		{#if dows.length}
			<div class="rounded-[10px] border border-edge bg-surface2 p-2.5">
				<div class="mb-1.5 text-[11px] font-bold uppercase tracking-[.04em] text-faint">
					Horário de cada dia
				</div>
				<div class="flex flex-col gap-1.5">
					{#each dows as d (d)}
						<div class="flex items-center gap-2.5">
							<span class="w-9 shrink-0 text-[12.5px] font-semibold text-muted">{DOW_LABELS[d]}</span>
							<input
								type="time"
								step="900"
								value={horarios[d] ?? '08:00'}
								oninput={(e) => (horarios = { ...horarios, [d]: e.currentTarget.value })}
								aria-label={`Horário de ${DOW_LABELS[d]}`}
								class="h-[34px] {CONTROL_CLASS} {CONTROL_PX} font-mono"
							/>
						</div>
					{/each}
				</div>
			</div>
		{:else}
			<p class="text-center text-[12px] text-faint">Selecione ao menos um dia.</p>
		{/if}

		{#if erro}
			<div class="mt-3 flex items-start gap-2 rounded-lg bg-danger/10 px-3 py-2.5 text-[12.5px] text-danger">
				<TriangleAlert size={16} class="mt-0.5 shrink-0" />
				<span>{erro}</span>
			</div>
		{/if}
	</form>

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-lg border border-edge px-3.5 py-2 text-[13px] font-semibold hover:bg-surface-2"
		>
			Cancelar
		</button>
		<SubmitButton
			emVoo={envio.emVoo}
			form="grade-form"
			disabled={!podeSalvar}
			class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary disabled:cursor-not-allowed disabled:opacity-50"
		>
			<SlidersHorizontal size={15} /> Salvar grade
		</SubmitButton>
	{/snippet}
</Modal>
