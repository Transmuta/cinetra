<script lang="ts">
	import ArrowRight from '@lucide/svelte/icons/arrow-right';
	import { fieldLabel, formatValue, type AuditResource, type DiffRow } from '$lib/audit';

	// O componente de diff campo-a-campo (doc 25 §11.4) — o único realmente novo da tela. Cada
	// linha: o rótulo do campo em português, o valor anterior (esmaecido) → o valor novo. Os
	// valores são formatados cientes do campo e do recurso (`formatValue`): datas viram hora
	// local da clínica, `status` vira rótulo, booleano vira Sim/Não.
	let {
		resource,
		diff,
		timezone
	}: {
		resource: AuditResource;
		diff: DiffRow[];
		timezone: string;
	} = $props();
</script>

{#if diff.length}
	<ul class="mt-1.5 flex flex-col gap-1">
		{#each diff as row (row.field)}
			<li class="flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-[12px] leading-tight">
				<span class="text-faint">{fieldLabel(row.field)}:</span>
				<span class="text-muted line-through decoration-edge-strong">
					{formatValue(resource, row.field, row.from, timezone)}
				</span>
				<ArrowRight size={11} class="text-faint" />
				<span class="font-semibold text-ink">
					{formatValue(resource, row.field, row.to, timezone)}
				</span>
			</li>
		{/each}
	</ul>
{/if}
