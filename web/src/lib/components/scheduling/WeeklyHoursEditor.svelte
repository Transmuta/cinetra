<script lang="ts">
	// Grade semanal da clínica, fiel a `cfgHorario` (:3239): uma linha por dia (Seg→Dom), com
	// toggle Aberto/Fechado e o `PeriodEditor`, mais "Espelhar Seg → Seg–Sex". Controlado:
	// recebe `hours` e emite a semana nova por `onchange`. Reutilizável pelo horário do
	// profissional depois (doc 22 §5).
	import Copy from '@lucide/svelte/icons/copy';
	import PeriodEditor from './PeriodEditor.svelte';
	import SwitchToggle from './SwitchToggle.svelte';
	import {
		WEEKDAYS,
		defaultDayPeriods,
		mirrorWeekdays,
		type Period,
		type WeekHours
	} from '$lib/scheduling';

	let { hours, onchange }: { hours: WeekHours; onchange: (next: WeekHours) => void } = $props();

	function setDay(dow: number, periods: Period[]) {
		onchange({ ...hours, [String(dow)]: periods });
	}
</script>

<div class="mb-1.5 flex items-center justify-between gap-3">
	<div class="text-[14px] font-semibold">Horário de atendimento da clínica</div>
	<button
		type="button"
		onclick={() => onchange(mirrorWeekdays(hours))}
		class="flex shrink-0 items-center gap-1.5 rounded-[7px] border border-edge bg-surface px-[11px] py-1.5 text-[12px] font-semibold text-accent-text hover:bg-surface-2"
	>
		<Copy size={13} /> Espelhar Seg → Seg–Sex
	</button>
</div>
<p class="mb-1.5 text-[12px] text-muted">
	Cada dia pode ter mais de um período (ex.: manhã e tarde, com intervalo de almoço).
</p>

{#each WEEKDAYS as { dow, label } (dow)}
	{@const periods = hours[String(dow)] ?? []}
	{@const open = periods.length > 0}
	<div class="flex items-start gap-3 border-t border-edge py-[11px]">
		<span class="w-[90px] pt-1.5 text-[13px] font-medium">{label}</span>

		<div class="min-w-0 flex-1">
			{#if open}
				<PeriodEditor {periods} onchange={(p) => setDay(dow, p)} />
			{:else}
				<span class="text-[12.5px] leading-[30px] text-faint">Fechado</span>
			{/if}
		</div>

		<div class="flex items-center gap-2 pt-1.5 text-[12px] text-muted">
			<SwitchToggle
				checked={open}
				label={label}
				onchange={() => setDay(dow, open ? [] : defaultDayPeriods())}
			/>
			<span class="w-[46px]">{open ? 'Aberto' : 'Fechado'}</span>
		</div>
	</div>
{/each}
