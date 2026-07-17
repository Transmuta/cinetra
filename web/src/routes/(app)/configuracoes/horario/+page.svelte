<script lang="ts">
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import type { SubmitFunction } from '@sveltejs/kit';
	import Circle from '@lucide/svelte/icons/circle';
	import WeeklyHoursEditor from '$lib/components/scheduling/WeeklyHoursEditor.svelte';
	import { canManageSchedule, formatPeriods, weekChanged, WEEKDAYS, type WeekHours } from '$lib/scheduling';
	import { toast } from '$lib/toast.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	// Todo membro lê; só owner/admin edita (H7 — a policy da API é a autoridade; aqui é UX).
	const canManage = $derived(canManageSchedule(data.me.papel));

	// Rascunho local: a semana inteira é editada e só então salva (protótipo `hoursDraft`).
	let draft = $state<WeekHours>(untrack(() => clone(data.clinicHours)));
	const dirty = $derived(weekChanged(draft, data.clinicHours));

	function clone(w: WeekHours): WeekHours {
		return structuredClone($state.snapshot(w)) as WeekHours;
	}

	const save: SubmitFunction = () => {
		return async ({ result, update }) => {
			await update({ reset: false });
			if (result.type === 'success') {
				draft = clone(data.clinicHours);
				toast('Horário da clínica salvo');
			} else if (form?.error) {
				toast(form.error);
			}
		};
	};

	function discard() {
		draft = clone(data.clinicHours);
		toast('Alterações descartadas');
	}
</script>

<svelte:head><title>Horário · Movimento</title></svelte:head>

<div class="mx-auto max-w-[760px] px-4 py-4 md:px-6">
	<section class="mb-3 rounded-[10px] border border-edge bg-surface p-4">
		{#if canManage}
			<WeeklyHoursEditor hours={draft} onchange={(next) => (draft = next)} />

			<div class="mt-4 flex items-center gap-2.5 border-t border-edge pt-3.5">
				<div
					class="flex flex-1 items-center gap-1.5 text-[12px] {dirty
						? 'font-semibold text-warning'
						: 'text-faint'}"
				>
					{#if dirty}
						<Circle size={8} class="fill-warning text-warning" /> Alterações não salvas
					{:else}
						Ao salvar, verificamos conflitos com agendamentos futuros.
					{/if}
				</div>

				{#if dirty}
					<button
						type="button"
						onclick={discard}
						class="rounded-lg border border-edge bg-surface px-3.5 py-2 text-[13px] font-semibold text-muted hover:bg-surface-2"
					>
						Descartar
					</button>
				{/if}

				<form method="POST" action="?/save" use:enhance={save}>
					<input type="hidden" name="clinic_hours" value={JSON.stringify(draft)} />
					<button
						type="submit"
						disabled={!dirty}
						class="rounded-lg bg-primary px-4 py-2 text-[13px] font-semibold text-on-primary hover:bg-primary-hover disabled:opacity-60"
					>
						Salvar
					</button>
				</form>
			</div>
		{:else}
			<!-- Leitura para não-gestores: o expediente sem os controles de edição. -->
			<h2 class="mb-2 text-[14px] font-semibold">Horário de atendimento da clínica</h2>
			{#each WEEKDAYS as { dow, label } (dow)}
				<div class="flex items-center gap-3 border-t border-edge py-2.5">
					<span class="w-[90px] text-[13px] font-medium">{label}</span>
					<span class="font-mono text-[12px] text-muted">
						{formatPeriods(data.clinicHours[String(dow)] ?? [])}
					</span>
				</div>
			{/each}
		{/if}
	</section>
</div>
