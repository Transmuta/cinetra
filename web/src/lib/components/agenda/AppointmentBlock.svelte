<script lang="ts">
	// O bloco do grid (protótipo `renderBlock` :1666).
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import CircleAlert from '@lucide/svelte/icons/circle-alert';
	import Package from '@lucide/svelte/icons/package';
	import { STATUS_META, type Appointment } from '$lib/agenda';
	import { blockGeometry, type Slot } from '$lib/agenda-layout';
	import { iconComponent } from '$lib/appointment-types';
	import type { AgendaAppointmentType } from '$lib/agenda';

	let {
		appt,
		tipo = undefined,
		slot,
		top,
		height,
		conflict = false,
		action = false,
		dragging = false,
		patientNames = [],
		profColor,
		startLabel,
		onSelect
	}: {
		appt: Appointment;
		tipo?: AgendaAppointmentType;
		slot: Slot;
		top: number;
		height: number;
		/** Sobrepõe outro agendamento do mesmo profissional (exibição — ver A-D2). */
		conflict?: boolean;
		/** Já terminou e ninguém resolveu (RN-58). */
		action?: boolean;
		/**
		 * Este é o bloco em arraste: esmaece para 0.4 enquanto o fantasma mostra o destino
		 * (protótipo `dragging` [`:1684`]). É o par visual do ghost — sem ele o bloco de origem
		 * fica parado e nada sinaliza que está "no ar".
		 */
		dragging?: boolean;
		patientNames?: string[];
		profColor: string;
		startLabel: string;
		onSelect: (id: string) => void;
	} = $props();

	const meta = $derived(STATUS_META[appt.status]);
	const geo = $derived(blockGeometry(slot));
	const TypeIcon = $derived(iconComponent(tipo?.icon ?? ''));

	// Ordem de precedência do protótipo (:1666): AÇÃO > conflito > tint do status. Ela
	// existe porque as três querem pintar o MESMO retângulo — sem ordem definida, o
	// resultado depende de qual regra roda por último.
	const variant = $derived(action ? 'action' : conflict ? 'conflict' : 'status');

	const grupo = $derived(!!tipo?.grupo);
	const capacidade = $derived(tipo?.capacidade ?? 4);

	// Rótulo por altura (:1687): abaixo de 30px não cabe a linha do nome em 12px; abaixo de
	// 58px não cabe a terceira linha.
	const titulo = $derived(
		grupo && tipo
			? `${tipo.nome} · ${appt.patient_ids.length}/${capacidade}`
			: // Um id sem correspondência no sidecar (paciente removido entre a leitura e o
				// render) vira um rótulo neutro — nunca o nome do TIPO, que faria um bloco
				// anônimo passar por um bloco identificado.
				(patientNames[0] ?? 'Paciente')
	);

	const rotulo = $derived(
		[startLabel, titulo, tipo?.nome, appt.encaixe ? 'encaixe' : null, meta.label]
			.filter(Boolean)
			.join(' · ')
	);

	// O fundo sai de `color-mix` sobre o token do tema, e não de um hex calculado em JS:
	// o valor do token muda entre claro e escuro, e um hex congelado quebraria o modo escuro.
	const fill = $derived(
		variant === 'action'
			? 'color-mix(in srgb, var(--color-warning) 16%, transparent)'
			: meta.tone
				? `color-mix(in srgb, var(--color-${meta.tone}) 12%, transparent)`
				: 'var(--color-surface)'
	);
	const stroke = $derived(
		variant === 'conflict'
			? 'var(--color-danger)'
			: variant === 'action'
				? 'var(--color-warning)'
				: meta.tone
					? `color-mix(in srgb, var(--color-${meta.tone}) 45%, transparent)`
					: 'var(--color-edge)'
	);
</script>

<button
	type="button"
	data-appt
	data-appt-id={appt.id}
	data-variant={variant}
	data-strike={meta.strike ? 'true' : undefined}
	aria-label={rotulo}
	onclick={(e) => {
		e.stopPropagation();
		onSelect(appt.id);
	}}
	style="top:{top}px; height:{Math.max(height - 2, 18)}px; left:{geo.left}; width:{geo.width};
	       background:{fill}; border-color:{stroke}; opacity:{dragging ? 0.4 : meta.dim ? 0.72 : 1};
	       transition:opacity .15s;
	       border-width:{variant === 'status' ? 1 : 1.5}px; z-index:{variant === 'conflict' ? 3 : 2};"
	class="absolute flex flex-col gap-0.5 overflow-hidden rounded-lg border border-solid px-1.5 py-1 text-left"
>
	{#if appt.package_id}
		<!-- Tarja do pacote (gancho da Fatia 3; aqui só sinaliza). -->
		<span class="absolute inset-y-0 left-0 w-[3px] rounded-l-lg bg-teal"></span>
	{/if}

	<div class="flex items-center gap-1.25">
		<span class="size-1.5 shrink-0 rounded-full" style="background:{profColor}"></span>
		<span class="font-mono text-[10.5px] font-semibold tabular-nums">{startLabel}</span>

		{#if conflict}
			<span title="Conflito de horário" class="text-danger"><TriangleAlert size={11} /></span>
		{/if}

		{#if action && !conflict}
			<span
				class="inline-flex items-center gap-0.75 rounded bg-warning px-1 text-[8.5px] font-extrabold tracking-wide text-white"
			>
				<CircleAlert size={9} /> AÇÃO
			</span>
		{/if}

		{#if appt.package_id}
			<span class="ml-auto text-teal-text"><Package size={10} /></span>
		{/if}

		<span class="{appt.package_id ? '' : 'ml-auto'} shrink-0 text-muted">
			<TypeIcon size={12} />
		</span>

		{#if meta.live}
			<span class="size-1.5 animate-pulse rounded-full bg-teal"></span>
		{/if}

		{#if appt.encaixe}
			<span class="rounded bg-warning px-1 text-[9px] font-bold text-white">ENCAIXE</span>
		{/if}
	</div>

	{#if height > 30}
		<div
			class="truncate text-[12px] font-semibold {meta.strike
				? 'text-faint line-through'
				: 'text-ink'}"
		>
			{titulo}
		</div>
	{:else}
		<div class="truncate text-[10.5px] {meta.strike ? 'text-faint line-through' : 'text-ink'}">
			{titulo}
		</div>
	{/if}

	{#if height > 58}
		<div class="mt-auto truncate text-[10px] text-faint">
			{#if grupo}
				{patientNames.slice(0, 3).join(', ')}{appt.patient_ids.length > 3
					? ` +${appt.patient_ids.length - 3}`
					: ''}
			{:else}
				{tipo?.nome ?? ''}
			{/if}
		</div>
	{/if}
</button>
