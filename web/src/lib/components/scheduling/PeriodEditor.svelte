<script lang="ts">
	// Editor de períodos de um dia, fiel ao `periodEditor` do protótipo (:3198): uma linha por
	// período (início – fim + remover) e um "+ período" tracejado. Controlado: recebe `periods`
	// e emite a lista nova por `onchange` — quem chama é dono do estado (dia da semana, exceção,
	// e, no futuro, o horário do profissional, que passa `min`/`max`).
	import X from '@lucide/svelte/icons/x';
	import Plus from '@lucide/svelte/icons/plus';
	import {
		appendPeriod,
		removePeriod,
		setPeriodTime,
		validateDayPeriods,
		type Period
	} from '$lib/scheduling';

	let {
		periods,
		min = undefined,
		max = undefined,
		onchange
	}: {
		periods: Period[];
		/** limites do horário (usados pelo editor do profissional; a clínica não restringe) */
		min?: string;
		max?: string;
		onchange: (next: Period[]) => void;
	} = $props();

	// Validação viva (espelho do servidor): aponta o input errado em vermelho + o motivo, em vez de
	// deixar o erro só aparecer como toast genérico depois do Salvar.
	const validation = $derived(validateDayPeriods(periods));

	const input =
		'h-[30px] min-w-0 max-w-[112px] flex-1 rounded-controle border bg-surface px-1.5 font-mono text-meta text-ink';
	const borderFor = (i: number) => (validation.badIndices.includes(i) ? 'border-danger' : 'border-edge');
</script>

<div class="flex flex-col gap-1.5">
	{#each periods as p, pi (pi)}
		<div class="flex items-center gap-1.5">
			<input
				type="time"
				step={900}
				{min}
				{max}
				value={p[0]}
				aria-label="Início do período {pi + 1}"
				aria-invalid={validation.badIndices.includes(pi)}
				onchange={(e) => onchange(setPeriodTime(periods, pi, 0, e.currentTarget.value))}
				class="{input} {borderFor(pi)}"
			/>
			<span class="text-faint">–</span>
			<input
				type="time"
				step={900}
				{min}
				{max}
				value={p[1]}
				aria-label="Fim do período {pi + 1}"
				aria-invalid={validation.badIndices.includes(pi)}
				onchange={(e) => onchange(setPeriodTime(periods, pi, 1, e.currentTarget.value))}
				class="{input} {borderFor(pi)}"
			/>
			<button
				type="button"
				title="Remover período"
				aria-label="Remover período {pi + 1}"
				onclick={() => onchange(removePeriod(periods, pi))}
				class="grid size-7 shrink-0 place-items-center rounded-controle border border-edge bg-surface text-danger hover:bg-surface-2"
			>
				<X size={13} />
			</button>
		</div>
	{/each}

	{#if validation.message}
		<p role="alert" class="text-meta font-medium text-danger">{validation.message}</p>
	{/if}

	<button
		type="button"
		onclick={() => onchange(appendPeriod(periods))}
		class="flex items-center gap-1 self-start rounded-controle border border-dashed border-edge px-2 py-[3px] text-meta font-semibold text-accent-text hover:bg-surface-2"
	>
		<Plus size={12} /> período
	</button>
</div>
