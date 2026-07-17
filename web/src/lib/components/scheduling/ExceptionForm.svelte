<script lang="ts">
	// Formulário de nova exceção, fiel a `cfgFeriados` (:3266): data + descrição + segmented
	// "Fechar o dia inteiro" / "Horário específico" + períodos condicionais. Envia para a action
	// `?/add`; reseta no sucesso. `tipo` e `periods` viajam por hidden inputs.
	import { enhance } from '$app/forms';
	import type { SubmitFunction } from '@sveltejs/kit';
	import PeriodEditor from './PeriodEditor.svelte';
	import { validateDayPeriods, type ExceptionKind, type Period } from '$lib/scheduling';

	let { error = null }: { error?: string | null } = $props();

	let data = $state('');
	let nome = $state('');
	let tipo = $state<ExceptionKind>('fechado');
	let periods = $state<Period[]>([['08:00', '12:00']]);
	let submitting = $state(false);

	const submit: SubmitFunction = () => {
		submitting = true;
		return async ({ result, update }) => {
			submitting = false;
			await update({ reset: false });
			if (result.type === 'success') {
				data = '';
				nome = '';
				tipo = 'fechado';
				periods = [['08:00', '12:00']];
			}
		};
	};

	const seg =
		'flex-1 rounded-[7px] border px-2 py-[7px] text-[12px] font-semibold cursor-pointer';

	// "Horário específico" com períodos inválidos trava o Adicionar (o PeriodEditor aponta o campo).
	const periodsInvalid = $derived(tipo === 'horario' && !validateDayPeriods(periods).ok);
</script>

<form
	method="POST"
	action="?/add"
	use:enhance={submit}
	class="mb-3.5 rounded-[10px] border border-edge bg-surface-2 p-3"
>
	<div class="mb-2.5 flex flex-wrap gap-2">
		<input
			type="date"
			name="data"
			bind:value={data}
			aria-label="Data da exceção"
			class="h-[38px] max-w-[170px] rounded-lg border border-edge bg-surface px-2.5 text-[13.5px] text-ink"
		/>
		<input
			name="nome"
			bind:value={nome}
			placeholder="Descrição (ex.: feriado, evento)"
			class="h-[38px] min-w-0 flex-1 rounded-lg border border-edge bg-surface px-2.5 text-[13.5px] text-ink"
		/>
	</div>

	<div class="mb-2.5 flex gap-1.5" role="group" aria-label="Tipo de exceção">
		<button
			type="button"
			onclick={() => (tipo = 'fechado')}
			aria-pressed={tipo === 'fechado'}
			class="{seg} {tipo === 'fechado'
				? 'border-teal bg-teal-subtle text-teal-text'
				: 'border-edge bg-surface text-muted'}"
		>
			Fechar o dia inteiro
		</button>
		<button
			type="button"
			onclick={() => (tipo = 'horario')}
			aria-pressed={tipo === 'horario'}
			class="{seg} {tipo === 'horario'
				? 'border-teal bg-teal-subtle text-teal-text'
				: 'border-edge bg-surface text-muted'}"
		>
			Horário específico
		</button>
	</div>
	<input type="hidden" name="tipo" value={tipo} />

	{#if tipo === 'horario'}
		<div class="mb-2.5">
			<p class="mb-1.5 text-[11.5px] text-muted">Períodos de atendimento neste dia:</p>
			<PeriodEditor {periods} onchange={(p) => (periods = p)} />
		</div>
		<input type="hidden" name="periods" value={JSON.stringify(periods)} />
	{/if}

	<button
		type="submit"
		disabled={submitting || data === '' || periodsInvalid}
		class="rounded-lg bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary hover:bg-primary-hover disabled:opacity-60"
	>
		Adicionar exceção
	</button>

	{#if error}
		<p class="mt-2.5 text-[12.5px] font-medium text-danger">{error}</p>
	{/if}
</form>
