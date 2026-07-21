<script lang="ts">
	// "Oferecer vaga" (protótipo `modalOferecer` :2621). Ao abrir, busca as vagas compatíveis do
	// item (o motor `find_slots`, via `/fila/[id]/slots`) e as agrupa por data. Clicar numa vaga
	// abre o passo de CONVERSÃO pré-preenchido (data/hora/profissional do slot), que submete a
	// `?/converter` — o `starts_at` em UTC sai de `toUtcIso` com o fuso da clínica (como o modal
	// de criar da agenda). O 422 `schedule_conflict` (ou o 409 `slot_held`, defensivo) reaparece
	// aqui com a saída de Encaixe.
	import { enhance } from '$app/forms';
	import Sparkles from '@lucide/svelte/icons/sparkles';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import ArrowLeft from '@lucide/svelte/icons/arrow-left';
	import Modal from '$lib/components/Modal.svelte';
	import Field, { CONTROL_CLASS, CONTROL_PX } from '$lib/components/Field.svelte';
	import EncaixeCheckbox from '$lib/components/agenda/EncaixeCheckbox.svelte';
	import ConflictErrorBox from '$lib/components/agenda/ConflictErrorBox.svelte';
	import PriorityBadge from './PriorityBadge.svelte';
	import { initials } from '$lib/format';
	import { avatarColor } from '$lib/avatar';
	import { stripTitle } from '$lib/patients';
	import { m2t, toUtcIso, canCreateEncaixe } from '$lib/agenda';
	import { ruleLabel, slotDateLabel, TIME_WINDOW_LABEL, type Entry, type Professional, type Slot } from '$lib/waitlist';
	import type { AppointmentType } from '$lib/appointment-types';
	import type { Papel } from '$lib/session';

	let {
		entry,
		preselect = null,
		professionals,
		appointmentTypes = [],
		timezone,
		papel = null,
		onClose,
		form = undefined
	}: {
		entry: Entry;
		/** Vaga pré-escolhida (clique num chip de vaga casada na lista): abre já no passo de conversão. */
		preselect?: Slot | null;
		professionals: Professional[];
		/** Tipos ativos E arquivados (o seletor filtra os ativos); vazio degrada o passo de conversão. */
		appointmentTypes?: AppointmentType[];
		/** Fuso da clínica (do /me), para a conversão vaga-local → instante UTC. */
		timezone: string;
		/** Espelho de UX do gate de Encaixe (A9/D2); a autoridade é a policy. */
		papel?: Papel | null;
		onClose: () => void;
		/** Resultado da action `converter` — traz `code`/`error` do 422 (`schedule_conflict`) ou 409. */
		form?: { action?: string; error?: string; code?: string } | null;
	} = $props();

	let loading = $state(true);
	let slots = $state<Slot[]>([]);
	// Pré-selecionada abre direto na conversão; "‹ Horários" volta à lista (buscada em segundo plano).
	// Captura só o valor inicial de propósito: o modal remonta a cada abertura (`{#if offering}`).
	// svelte-ignore state_referenced_locally
	let selected = $state<Slot | null>(preselect);
	let encaixe = $state(false);
	let obs = $state('');

	const tipos = $derived(appointmentTypes.filter((t) => t.ativo));
	let typeId = $state('');
	// O tipo default entra quando os tipos chegam (o prop existe no mount, mas fica explícito).
	$effect(() => {
		if (!typeId && tipos.length) typeId = tipos[0].id;
	});

	// Busca as vagas ao abrir. `/fila/[id]/slots` degrada para `[]` na falha — o modal mostra o
	// vazio, não estoura. `alive` evita escrever em `$state` de um modal já fechado (timer órfão).
	$effect(() => {
		let alive = true;
		fetch(`/fila/${encodeURIComponent(entry.id)}/slots`)
			.then((r) => (r.ok ? r.json() : { slots: [] }))
			.then((d: { slots?: Slot[] }) => {
				if (!alive) return;
				slots = d.slots ?? [];
				loading = false;
			})
			.catch(() => {
				if (alive) loading = false;
			});
		return () => {
			alive = false;
		};
	});

	function profName(id: string): string {
		const p = professionals.find((x) => x.id === id);
		return p ? stripTitle(p.nome) : '';
	}
	function profCor(id: string): number {
		return professionals.find((x) => x.id === id)?.cor_indice ?? 1;
	}

	// Vagas por data (protótipo :2629): no máximo 6 datas, 8 vagas cada.
	const byDate = $derived.by(() => {
		const out: Record<string, Slot[]> = {};
		for (const s of slots) (out[s.date] ??= []).push(s);
		return out;
	});
	const dates = $derived(Object.keys(byDate).sort().slice(0, 6));

	// Cabeçalho de cada dia: "Quinta-Feira, 25/06" (capitalizado no CSS). UTC no parse para não
	// recuar um dia a oeste de Greenwich (mesmo motivo de `agenda.dayLabel`).
	const HEADER_FMT = new Intl.DateTimeFormat('pt-BR', {
		weekday: 'long',
		day: '2-digit',
		month: '2-digit',
		timeZone: 'UTC'
	});
	function dateHeader(date: string): string {
		return HEADER_FMT.format(new Date(`${date}T12:00:00Z`));
	}

	// Resumo da disponibilidade (protótipo :2631): janela · regras · profissionais preferidos.
	const summary = $derived.by(() => {
		const jan = entry.janela === 'qualquer' ? 'Qualquer horário' : TIME_WINDOW_LABEL[entry.janela];
		const regras = entry.rules.map(ruleLabel).filter((r) => r !== '—');
		const profs = entry.professional_ids.length
			? entry.professional_ids.map(profName).filter(Boolean).join(', ')
			: 'Qualquer profissional';
		return [jan, ...regras, profs].join('  ·  ');
	});

	const startsAt = $derived(selected ? toUtcIso(selected.date, m2t(selected.start), timezone) : '');
	const podeEncaixe = $derived(canCreateEncaixe(papel));

	// O conflito devolvido pela conversão. `schedule_conflict` (422) oferece Encaixe; `slot_held`
	// (409, defensivo) só mostra quem está segurando — não há saída de encaixe para reserva alheia.
	const conflito = $derived(form?.action === 'converter' && form?.code === 'schedule_conflict');
	const erro = $derived(form?.action === 'converter' ? form?.error : undefined);
	const ofereceEncaixe = $derived(conflito && podeEncaixe && !encaixe);

	function firstName(nome: string): string {
		return nome.trim().split(/\s+/)[0] ?? nome;
	}
</script>

<Modal title={`Oferecer vaga — ${firstName(entry.patient.nome)}`} {onClose} maxWidth="max-w-[560px]">
	<!-- Cabeçalho do paciente: avatar (cor do 1º preferido) + nome + resumo + prioridade. -->
	<div class="mb-3.5 flex items-center gap-3 border-b border-edge pb-3">
		<span
			class="grid size-9 shrink-0 place-items-center rounded-full text-[12px] font-bold text-white"
			style="background:{avatarColor(profCor(entry.professional_ids[0] ?? ''))}"
		>
			{initials(entry.patient.nome)}
		</span>
		<div class="min-w-0 flex-1">
			<div class="text-[14px] font-semibold">{entry.patient.nome}</div>
			<div class="truncate text-[11.5px] text-muted">{summary}</div>
		</div>
		<PriorityBadge prio={entry.prio} />
	</div>

	{#if selected}
		<!-- Passo de conversão: a vaga escolhida + tipo/observação, submetido a ?/converter. -->
		<form id="fila-converter" method="POST" action="?/converter" use:enhance>
			<input type="hidden" name="id" value={entry.id} />
			<input type="hidden" name="starts_at" value={startsAt} />
			<input type="hidden" name="professional_id" value={selected.professional_id} />

			<div class="mb-3 flex items-center gap-2.5 rounded-[10px] border border-teal-border bg-teal-subtle px-3 py-2.5 text-teal-text">
				<CalendarClock size={16} class="shrink-0" />
				<span class="text-[12.5px] font-semibold capitalize">{dateHeader(selected.date)}</span>
				<span class="font-mono text-[13px] font-bold">{m2t(selected.start)}</span>
				<span class="ml-auto text-[12px]">{profName(selected.professional_id)}</span>
			</div>

			<Field label="Tipo de atendimento">
				{#snippet control()}
					<select name="appointment_type_id" bind:value={typeId} class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}">
						{#each tipos as t (t.id)}
							<option value={t.id}>{t.nome} ({t.duracao_minutos}min){t.grupo ? ' · grupo' : ''}</option>
						{/each}
					</select>
				{/snippet}
			</Field>

			<Field label="Observação">
				{#snippet control()}
					<input
						name="obs"
						bind:value={obs}
						maxlength="500"
						placeholder="Ex.: vem de muleta, trazer exame. Não é prontuário."
						class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}"
					/>
				{/snippet}
			</Field>

			<EncaixeCheckbox bind:checked={encaixe} {podeEncaixe} />
			<ConflictErrorBox {erro} {ofereceEncaixe} onEncaixe={() => (encaixe = true)} />
		</form>
	{:else if loading}
		<div class="py-10 text-center text-[13px] text-faint">Buscando horários livres…</div>
	{:else if dates.length}
		<div class="mb-3 flex items-center gap-1.75 text-[12.5px] text-muted">
			<Sparkles size={15} class="shrink-0 text-teal-text" />
			<span>Horários livres que batem com a disponibilidade — clique para agendar.</span>
		</div>
		<div class="flex flex-col gap-3">
			{#each dates as date (date)}
				<div>
					<div class="mb-1.75 text-[11px] font-semibold capitalize tracking-[.02em] text-faint">
						{dateHeader(date)}
					</div>
					<div class="flex flex-wrap gap-1.75">
						{#each byDate[date].slice(0, 8) as slot (slot.professional_id + '-' + slot.start)}
							<button
								type="button"
								onclick={() => (selected = slot)}
								title={`Oferecer ${slotDateLabel(slot)} às ${m2t(slot.start)}${slot.freed ? ' · vaga que abriu' : ''}`}
								class="inline-flex items-center gap-2 rounded-[9px] border px-3 py-2 text-[12.5px] {slot.freed
									? 'border-teal bg-teal text-white'
									: 'border-teal-border bg-teal-subtle text-teal-text'}"
							>
								<span class="font-mono text-[13px] font-bold">{m2t(slot.start)}</span>
								<span class="inline-flex items-center gap-1.5 {slot.freed ? 'text-white/90' : 'text-muted'}">
									<span
										class="grid size-4 place-items-center rounded-full text-[8px] font-bold text-white"
										style="background:{avatarColor(profCor(slot.professional_id))}"
									>
										{initials(profName(slot.professional_id))}
									</span>
									{profName(slot.professional_id)}
								</span>
								{#if slot.freed}
									<span class="rounded bg-white/25 px-1 py-px text-[8.5px] font-extrabold tracking-[.05em]">ABRIU</span>
								{/if}
							</button>
						{/each}
					</div>
				</div>
			{/each}
		</div>
	{:else}
		<div class="px-4 py-7 text-center text-faint">
			<CalendarClock size={26} class="mx-auto" />
			<div class="mt-2.5 text-[13.5px] font-semibold text-muted">
				Nenhuma vaga compatível nos próximos 14 dias
			</div>
			<div class="mx-auto mt-0.75 max-w-[340px] text-[12.5px]">
				A disponibilidade do paciente não coincide com horários livres. Reveja a disponibilidade ou
				agende manualmente pela Agenda.
			</div>
		</div>
	{/if}

	{#snippet footer()}
		{#if selected}
			<button
				type="button"
				onclick={() => (selected = null)}
				class="inline-flex items-center gap-1.5 rounded-md border border-edge-strong bg-surface px-3.5 py-2 text-[13px] font-semibold hover:bg-surface-2"
			>
				<ArrowLeft size={14} /> Horários
			</button>
			<button
				type="submit"
				form="fila-converter"
				disabled={!typeId}
				class="rounded-md bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary disabled:cursor-not-allowed disabled:opacity-60"
			>
				Agendar
			</button>
		{:else}
			<button
				type="button"
				onclick={onClose}
				class="rounded-md border border-edge-strong bg-surface px-3.5 py-2 text-[13px] font-semibold hover:bg-surface-2"
			>
				Fechar
			</button>
		{/if}
	{/snippet}
</Modal>
