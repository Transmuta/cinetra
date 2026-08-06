<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import { envio } from '$lib/forms.svelte';
	import Circle from '@lucide/svelte/icons/circle';
	import WeeklyHoursEditor from '$lib/components/scheduling/WeeklyHoursEditor.svelte';
	import {
		canManageSchedule,
		formatPeriods,
		weekChanged,
		weekHasErrors,
		WEEKDAYS,
		type WeekHours
	} from '$lib/scheduling';
	import { toast } from '$lib/toast.svelte';
	import ConflictsModal from '$lib/components/scheduling/ConflictsModal.svelte';
	import { parseFutureConflicts, type FutureConflicts } from '$lib/scheduling-conflicts';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	// Todo membro lê; só owner/admin edita (H7 — a policy da API é a autoridade; aqui é UX).
	const canManage = $derived(canManageSchedule(data.me.papel));

	// Rascunho local: a semana inteira é editada e só então salva (protótipo `hoursDraft`).
	let draft = $state<WeekHours>(untrack(() => clone(data.clinicHours)));
	const dirty = $derived(weekChanged(draft, data.clinicHours));
	// Trava o Salvar enquanto há período inválido (o PeriodEditor já aponta qual). A API continua
	// sendo a autoridade — isto só evita o round-trip e o toast genérico para erros que a tela vê.
	const hasErrors = $derived(weekHasErrors(draft));

	function clone(w: WeekHours): WeekHours {
		return structuredClone($state.snapshot(w)) as WeekHours;
	}

	// A3/D12 — os conflitos que o servidor devolveu no 409. O modal é só AVISO: não existe
	// "salvar mesmo assim", então não há o que reenviar.
	let conflitos = $state<FutureConflicts | null>(null);

	const save = envio({
		reset: false,
		aoResponder: (result) => {
			if (result.type === 'success') {
				draft = clone(data.clinicHours);
				conflitos = null;
				toast('Horário da clínica salvo');
			} else if (result.type === 'failure') {
				// 409 com a lista → modal. Qualquer outro erro (ex.: períodos inválidos → 422) vira
				// toast. Lemos do `result` (fresco), não do prop `form` (que só atualiza depois do
				// update e podia ficar defasado).
				const achados = parseFutureConflicts(result.data?.code, result.data?.meta);

				if (achados) {
					conflitos = achados;
				} else {
					conflitos = null;

					const message = result.data?.error;
					toast(
						typeof message === 'string' ? message : 'Não foi possível salvar o horário.',
						'error'
					);
				}
			}
		}
	});

	function discard() {
		draft = clone(data.clinicHours);
		toast('Alterações descartadas');
	}
</script>

<svelte:head><title>Horário · Cinetra</title></svelte:head>

<div class="mx-auto max-w-[760px] px-4 py-4 md:px-6">
	<section class="mb-3 rounded-cartao border border-edge bg-surface p-4">
		{#if canManage}
			<WeeklyHoursEditor hours={draft} onchange={(next) => (draft = next)} />

			<div class="mt-4 flex items-center gap-2.5 border-t border-edge pt-3.5">
				<div
					class="flex flex-1 items-center gap-1.5 text-rotulo {hasErrors
						? 'font-semibold text-danger'
						: dirty
							? 'font-semibold text-warning'
							: 'text-faint'}"
				>
					{#if hasErrors}
						<Circle size={8} class="fill-danger text-danger" /> Corrija os horários destacados.
					{:else if dirty}
						<Circle size={8} class="fill-warning text-warning" /> Alterações não salvas
					{:else}
						Ao salvar, verificamos conflitos com agendamentos futuros.
					{/if}
				</div>

				{#if dirty}
					<button
						type="button"
						onclick={discard}
						class="rounded-controle border border-edge bg-surface px-3.5 py-2 text-corpo font-semibold text-muted hover:bg-surface-2"
					>
						Descartar
					</button>
				{/if}

				<form method="POST" action="?/save" use:enhance={save.submit}>
					<input type="hidden" name="clinic_hours" value={JSON.stringify(draft)} />
					<Button type="submit"
						emVoo={save.emVoo}
						disabled={!dirty || hasErrors}
					>
						Salvar
					</Button>
				</form>
			</div>
		{:else}
			<!-- Leitura para não-gestores: o expediente sem os controles de edição. -->
			<h2 class="mb-2 text-leitura font-semibold">Horário de atendimento da clínica</h2>
			{#each WEEKDAYS as { dow, label } (dow)}
				<div class="flex items-center gap-3 border-t border-edge py-2.5">
					<span class="w-[90px] text-corpo font-medium">{label}</span>
					<span class="font-mono text-rotulo text-muted">
						{formatPeriods(data.clinicHours[String(dow)] ?? [])}
					</span>
				</div>
			{/each}
		{/if}
	</section>
</div>

{#if conflitos}
	<ConflictsModal {conflitos} onClose={() => (conflitos = null)} />
{/if}
