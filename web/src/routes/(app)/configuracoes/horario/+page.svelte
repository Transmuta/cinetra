<script lang="ts">
	import { untrack, tick } from 'svelte';
	import { enhance } from '$app/forms';
	import type { SubmitFunction } from '@sveltejs/kit';
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

	// A3/D12 — os conflitos que o servidor devolveu no 409, e o formulário que os reenvia com
	// `confirm`. O modal é a ÚNICA porta para o confirm: ninguém aplica sem ter visto a lista.
	let conflitos = $state<FutureConflicts | null>(null);
	let formEl: HTMLFormElement | null = $state(null);
	let confirmando = $state(false);

	const save: SubmitFunction = () => {
		return async ({ result, update }) => {
			await update({ reset: false });
			if (result.type === 'success') {
				draft = clone(data.clinicHours);
				conflitos = null;
				confirmando = false;
				toast('Horário da clínica salvo');
			} else if (result.type === 'failure') {
				// 409 com a lista → modal. Qualquer outro erro (ex.: períodos inválidos → 422) vira
				// toast. Lemos do `result` (fresco), não do prop `form` (que só atualiza depois do
				// update e podia ficar defasado).
				const achados = parseFutureConflicts(result.data?.code, result.data?.meta);

				if (achados) {
					conflitos = achados;
				} else {
					// Erro que NÃO é conflito zera o `confirmando` (bate-volta doc 49): sem isto,
					// uma tentativa confirmada que falhasse por outro motivo deixaria a flag ligada,
					// e o próximo "Salvar" pularia o gate **sem** a pessoa ver lista nenhuma.
					conflitos = null;
					confirmando = false;

					const message = result.data?.error;
					toast(
						typeof message === 'string' ? message : 'Não foi possível salvar o horário.',
						'error'
					);
				}
			}
		};
	};

	// Reenvia a MESMA semana com `confirm=true`.
	//
	// O `await tick()` NÃO é decorativo: no Svelte 5 o DOM só é atualizado no flush, e um
	// `requestSubmit()` no mesmo tick submeteria o hidden com o valor ANTIGO — o form iria com
	// `confirm=false` e o servidor recusaria de novo, para sempre. É o mesmo tropeço que a
	// presença da turma pagou (doc 41), e ali só o clique ao vivo revelou.
	async function aplicarMesmoAssim() {
		confirmando = true;
		await tick();
		formEl?.requestSubmit();
	}

	function discard() {
		draft = clone(data.clinicHours);
		toast('Alterações descartadas');
	}
</script>

<svelte:head><title>Horário · Cinetra</title></svelte:head>

<div class="mx-auto max-w-[760px] px-4 py-4 md:px-6">
	<section class="mb-3 rounded-[10px] border border-edge bg-surface p-4">
		{#if canManage}
			<WeeklyHoursEditor hours={draft} onchange={(next) => (draft = next)} />

			<div class="mt-4 flex items-center gap-2.5 border-t border-edge pt-3.5">
				<div
					class="flex flex-1 items-center gap-1.5 text-[12px] {hasErrors
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
						class="rounded-lg border border-edge bg-surface px-3.5 py-2 text-[13px] font-semibold text-muted hover:bg-surface-2"
					>
						Descartar
					</button>
				{/if}

				<form method="POST" action="?/save" use:enhance={save} bind:this={formEl}>
					<input type="hidden" name="clinic_hours" value={JSON.stringify(draft)} />
					<input type="hidden" name="confirm" value={confirmando ? 'true' : 'false'} />
					<button
						type="submit"
						disabled={!dirty || hasErrors}
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

{#if conflitos}
	<ConflictsModal
		{conflitos}
		onClose={() => {
			conflitos = null;
			confirmando = false;
		}}
		onConfirm={aplicarMesmoAssim}
	/>
{/if}
