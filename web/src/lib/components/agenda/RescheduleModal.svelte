<script lang="ts">
	// "Remarcar sessão" (protótipo `modalRemarcar` :2266), Entrega 4. Move UMA sessão: data,
	// hora e coluna (profissional). Não redimensiona — a duração é preservada no servidor
	// (`ShiftEndsAt`). GAP-03 corrigido: o servidor valida expediente igual ao "Novo
	// agendamento", então remarcar para o almoço/feriado é recusado aqui também.
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import Modal from '$lib/components/Modal.svelte';
	import Field, { CONTROL_CLASS, CONTROL_PX } from '$lib/components/Field.svelte';
	import ConflictErrorBox from './ConflictErrorBox.svelte';
	import EncaixeCheckbox from './EncaixeCheckbox.svelte';
	import {
		canCreateEncaixe,
		toUtcIso,
		zonedParts,
		m2t,
		type Appointment,
		type AgendaProfessional
	} from '$lib/agenda';
	import type { Papel } from '$lib/session';

	let {
		appt,
		timezone,
		professionals,
		papel,
		form = null,
		onClose
	}: {
		appt: Appointment;
		timezone: string;
		professionals: AgendaProfessional[];
		papel: Papel | null;
		form?: { action?: string; error?: string; code?: string } | null;
		onClose: () => void;
	} = $props();

	// Parte do estado ATUAL do bloco, no relógio da clínica (não de Date.now()). `untrack`
	// porque isto é o valor INICIAL dos campos, que passam a ser do usuário (mesmo padrão do
	// NewAppointmentModal): o modal é montado por abertura.
	const parts = untrack(() => zonedParts(appt.starts_at, timezone));

	let dataStr = $state(parts.date);
	let hora = $state(m2t(parts.minutes));
	let profId = $state(untrack(() => appt.professional_id));
	let encaixe = $state(false);

	const startsAt = $derived(toUtcIso(dataStr, hora, timezone));
	const podeEncaixe = $derived(canCreateEncaixe(papel));

	// A-D2(b): o servidor recusou por conflito e a saída (encaixe) existe — alcançável porque o
	// BFF propaga o `code` do 422. Fora do expediente NÃO há encaixe a oferecer (D14).
	const conflito = $derived(form?.action === 'remarcar' && form?.code === 'schedule_conflict');
	const erro = $derived(form?.action === 'remarcar' ? form?.error : undefined);
	const ofereceEncaixe = $derived(conflito && podeEncaixe && !encaixe);

	const mudou = $derived(startsAt !== appt.starts_at || profId !== appt.professional_id || encaixe);
</script>

<Modal title="Remarcar sessão" {onClose} maxWidth="max-w-[460px]">
	<form id="remarcar" method="POST" action="?/remarcar" use:enhance>
		<input type="hidden" name="id" value={appt.id} />
		<input type="hidden" name="expected_version" value={appt.version} />
		<input type="hidden" name="starts_at" value={startsAt} />

		<div class="grid grid-cols-2 gap-2.5">
			<Field label="Data" type="date" bind:value={dataStr} />
			<!-- step=900: sugere de 15 em 15, mas não é regra (A-D1). -->
			<Field label="Hora" type="time" step={900} mono bind:value={hora} />
		</div>

		<Field label="Profissional">
			{#snippet control()}
				<select
					name="professional_id"
					bind:value={profId}
					class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}"
				>
					{#each professionals as p (p.id)}
						<option value={p.id}>{p.nome_exibicao ?? p.nome}</option>
					{/each}
				</select>
			{/snippet}
		</Field>

		<EncaixeCheckbox bind:checked={encaixe} {podeEncaixe} />

		<ConflictErrorBox {erro} {ofereceEncaixe} onEncaixe={() => (encaixe = true)} />
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
			form="remarcar"
			disabled={!mudou}
			class="rounded-md bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary disabled:cursor-not-allowed disabled:opacity-60"
		>
			Remarcar
		</button>
	{/snippet}
</Modal>
