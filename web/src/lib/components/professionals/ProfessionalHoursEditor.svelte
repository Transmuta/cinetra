<script lang="ts">
	// Grade do profissional quando ele NÃO segue o horário da clínica (fiel a `dayRow` :2991):
	// uma linha por dia (Seg→Dom) com toggle Atende/Não atende e o `PeriodEditor` limitado ao
	// expediente da clínica. Dia em que a clínica fecha aparece travado ("Clínica fechada"). O
	// invariante prof ⊆ clínica é apontado no próprio dia (input vermelho + motivo). Controlado:
	// recebe `grade` (dow → períodos | null) e o expediente da clínica, emite por `onchange`.
	import PeriodEditor from '$lib/components/scheduling/PeriodEditor.svelte';
	import SwitchToggle from '$lib/components/scheduling/SwitchToggle.svelte';
	import {
		WEEKDAYS,
		formatPeriods,
		periodsWithinClinic,
		type GradeState,
		type HoursRow
	} from '$lib/professionals';
	import { validateDayPeriods, type Period } from '$lib/scheduling';

	let {
		clinicHours,
		grade,
		onchange
	}: {
		clinicHours: HoursRow[];
		grade: GradeState;
		onchange: (next: GradeState) => void;
	} = $props();

	const clinicMap = $derived(Object.fromEntries(clinicHours.map((r) => [r.dow, r.periods])));

	function clinicDay(dow: number): Period[] {
		return clinicMap[dow] ?? [];
	}

	function setDay(dow: number, periods: Period[] | null) {
		onchange({ ...grade, [dow]: periods });
	}

	// Liga/desliga o dia: ao ligar, copia o expediente da clínica (o profissional começa igual e
	// depois estreita); ao desligar, "não atende".
	function toggle(dow: number, on: boolean) {
		if (!on) return setDay(dow, null);
		const clinic = clinicDay(dow);
		if (!clinic.length) return; // clínica fechada — nada a ligar
		const current = grade[dow];
		setDay(dow, current && current.length ? current : clinic.map(([i, f]): Period => [i, f]));
	}

	// Motivo de erro do dia: forma inválida (PeriodEditor já pinta) OU fora do horário da clínica.
	function dayError(dow: number, periods: Period[]): string | null {
		if (!validateDayPeriods(periods).ok) return null; // o PeriodEditor já mostra a mensagem
		if (!periodsWithinClinic(periods, clinicDay(dow)))
			return `Deve ficar dentro do horário da clínica (${formatPeriods(clinicDay(dow))})`;
		return null;
	}
</script>

<div class="overflow-hidden rounded-lg border border-edge">
	{#each WEEKDAYS as { dow, label } (dow)}
		{@const clinic = clinicDay(dow)}
		{@const clinicOpen = clinic.length > 0}
		{@const day = grade[dow]}
		{@const on = clinicOpen && Array.isArray(day) && day.length > 0}
		{@const err = on ? dayError(dow, day as Period[]) : null}
		<div
			class="flex items-start gap-3 border-t border-edge px-2.5 py-[9px] first:border-t-0 {on
				? ''
				: 'bg-surface-2'}"
		>
			<div class="flex w-[120px] shrink-0 items-center gap-2 pt-[3px]">
				<SwitchToggle
					checked={on}
					disabled={!clinicOpen}
					label={label}
					onchange={() => toggle(dow, !on)}
				/>
				<span class="text-[12.5px] font-semibold {clinicOpen ? '' : 'text-faint'}">{label}</span>
			</div>

			<div class="min-w-0 flex-1">
				{#if !clinicOpen}
					<span class="text-[12px] leading-[30px] text-faint">Clínica fechada</span>
				{:else if on}
					<PeriodEditor
						periods={day as Period[]}
						min={clinic[0][0]}
						max={clinic[clinic.length - 1][1]}
						onchange={(p) => setDay(dow, p)}
					/>
					<p class="mt-1 font-mono text-[10.5px] {err ? 'text-danger' : 'text-faint'}">
						{err ?? `Clínica: ${formatPeriods(clinic)}`}
					</p>
				{:else}
					<span class="text-[12px] leading-[30px] text-faint">Não atende</span>
				{/if}
			</div>
		</div>
	{/each}
</div>
