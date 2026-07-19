<script lang="ts">
	// "Novo agendamento" (protótipo `modalNovoAgendamento` :1965).
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Modal from '$lib/components/Modal.svelte';
	import Field, { CONTROL_CLASS, CONTROL_PX } from '$lib/components/Field.svelte';
	import PatientPicker from './PatientPicker.svelte';
	import {
		canCreateEncaixe,
		toUtcIso,
		type AgendaPatient,
		type AgendaProfessional,
		type SearchResult,
		type AgendaAppointmentType
	} from '$lib/agenda';
	import type { Papel } from '$lib/session';

	let {
		date,
		timezone,
		professionals,
		appointmentTypes,
		papel,
		preset,
		onClose,
		search,
		form = undefined
	}: {
		date: string;
		timezone: string;
		professionals: AgendaProfessional[];
		appointmentTypes: AgendaAppointmentType[];
		papel: Papel | null;
		preset: { professional_id: string; hora: string };
		onClose: () => void;
		search: (q: string) => Promise<SearchResult>;
		/** Resultado da action `criar` — traz `code`/`error` do 422. */
		form?: { action?: string; error?: string; code?: string } | null;
	} = $props();

	// NÃO filtrar por `t.ativo` aqui: `/api/appointments` já devolve só os ativos e não manda
	// o campo — o filtro do cliente esvaziaria o seletor inteiro (campo `undefined`).
	const ativos = $derived(appointmentTypes);

	// `untrack`: o modal é montado por abertura, então estes campos partem do preset UMA vez
	// e passam a ser do usuário. Sem isto, o Svelte avisa (com razão) que a leitura só captura
	// o valor inicial — aqui isso é o comportamento desejado, e o untrack o torna explícito.
	// Mesmo padrão de `pacientes/+page.svelte:33`.
	let dataStr = $state(untrack(() => date));
	let hora = $state(untrack(() => preset.hora));
	let profId = $state(untrack(() => preset.professional_id));
	let typeId = $state(untrack(() => ativos[0]?.id ?? ''));
	let encaixe = $state(false);
	let obs = $state('');
	let selected = $state<AgendaPatient[]>([]);

	const tipo = $derived(ativos.find((t) => t.id === typeId));
	const grupo = $derived(!!tipo?.grupo);
	const capacidade = $derived(tipo?.capacidade ?? 4);
	const titulo = $derived(grupo ? 'Novo agendamento em grupo' : 'Novo agendamento');

	// A conversão relógio-da-clínica → instante absoluto acontece AQUI, com o fuso vindo do
	// servidor no load. Errar isto faz todo agendamento nascer com horas de diferença, e o
	// erro é invisível numa máquina que rode em UTC.
	const startsAt = $derived(toUtcIso(dataStr, hora, timezone));

	const podeEncaixe = $derived(canCreateEncaixe(papel));

	// A-D2(b): o servidor recusou por conflito e a saída existe — mas só é alcançável porque
	// o BFF passou a propagar o `code` do 422 (antes tudo virava "Dados inválidos").
	const conflito = $derived(form?.action === 'criar' && form?.code === 'schedule_conflict');
	const erro = $derived(form?.action === 'criar' ? form?.error : undefined);

	// Encaixe NÃO libera indisponibilidade (D14): fora do expediente não há saída a oferecer.
	const ofereceEncaixe = $derived(conflito && podeEncaixe && !encaixe);

	const podeSalvar = $derived(selected.length > 0 && !!profId && !!typeId);

	function pick(p: AgendaPatient) {
		if (selected.some((s) => s.id === p.id)) return;
		selected = grupo ? [...selected, p] : [p];
	}
</script>

<Modal title={titulo} {onClose} maxWidth="max-w-[520px]">
	<form id="novo-agendamento" method="POST" action="?/criar" use:enhance>
		<input type="hidden" name="starts_at" value={startsAt} />
		<input type="hidden" name="patient_ids" value={JSON.stringify(selected.map((p) => p.id))} />

		<Field label={grupo ? `Participantes (${selected.length}/${capacidade})` : 'Paciente'}>
			<PatientPicker
				{selected}
				multi={grupo}
				{search}
				onPick={pick}
				onRemove={(id) => (selected = selected.filter((p) => p.id !== id))}
			/>
		</Field>

		<div class="grid grid-cols-2 gap-2.5">
			<Field label="Profissional">
				{#snippet control()}
					<select name="professional_id" bind:value={profId} class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}">
						{#each professionals as p (p.id)}
							<option value={p.id}>{p.nome_exibicao ?? p.nome}</option>
						{/each}
					</select>
				{/snippet}
			</Field>

			<Field label="Tipo">
				{#snippet control()}
					<select name="appointment_type_id" bind:value={typeId} class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}">
						{#each ativos as t (t.id)}
							<option value={t.id}>
								{t.nome} ({t.duracao_minutos}min){t.grupo ? ' · grupo' : ''}
							</option>
						{/each}
					</select>
				{/snippet}
			</Field>
		</div>

		<div class="grid grid-cols-2 gap-2.5">
			<Field label="Data" type="date" bind:value={dataStr} />

			<!-- step=900: a UI SUGERE de 15 em 15, mas A-D1 decidiu que não é regra —
			     um encaixe às 10:07 combinado por telefone tem que poder ser salvo. -->
			<Field label="Hora" type="time" step={900} mono bind:value={hora} />
		</div>

		<Field label="Observação">
			{#snippet control()}
				<textarea
					name="obs"
					bind:value={obs}
					maxlength="500"
					rows="2"
					placeholder="Ex.: vem de muleta, trazer exame. Não é prontuário."
					class="w-full py-2 {CONTROL_CLASS} {CONTROL_PX}"
				></textarea>
			{/snippet}
		</Field>

		{#if podeEncaixe}
			<label class="flex cursor-pointer items-center gap-2 py-1 text-[13px]">
				<input
					type="checkbox"
					name="encaixe"
					bind:checked={encaixe}
					class="size-4 accent-teal"
				/>
				Encaixe
				<span class="text-[12px] text-faint">(ignora conflito de horário)</span>
			</label>
		{/if}

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
							onclick={() => (encaixe = true)}
							class="mt-1.5 rounded-md border border-current px-2 py-1 text-[12px] font-semibold"
						>
							Marcar como encaixe
						</button>
					{/if}
				</div>
			</div>
		{/if}
	</form>

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-md border border-edge-strong bg-surface px-3.5 py-2 text-[13px] font-semibold hover:bg-surface-2"
		>
			Cancelar
		</button>
		<button
			type="submit"
			form="novo-agendamento"
			disabled={!podeSalvar}
			class="rounded-md bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary disabled:cursor-not-allowed disabled:opacity-60"
		>
			Agendar
		</button>
	{/snippet}
</Modal>
