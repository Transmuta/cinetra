<script lang="ts">
	import ArrowRight from '@lucide/svelte/icons/arrow-right';
	import { fieldLabel, formatValue, type AuditResource, type DiffRow } from '$lib/audit';

	// O componente de diff campo-a-campo (doc 25 §11.4) — o único realmente novo da tela. Cada
	// linha: o rótulo do campo em português, o valor anterior (esmaecido) → o valor novo. Os
	// valores são formatados cientes do campo e do recurso (`formatValue`): datas viram hora
	// local da clínica, `status` vira rótulo, booleano vira Sim/Não.
	//
	// Uma linha **redigida** (D-Aud4, doc 63) não tem valores para mostrar: CPF, RG e dados
	// bancários entram na trilha como "este campo mudou" e nada mais. Ela é renderizada como tal,
	// e não omitida: omitir faria a tela afirmar que o campo NÃO mudou, que é a única leitura
	// pior do que não saber o valor.
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
	<ul class="mt-1 flex flex-col gap-1">
		{#each diff as row (row.field)}
			{@const antes = formatValue(resource, row.field, row.from, timezone)}
			{@const depois = formatValue(resource, row.field, row.to, timezone)}
			<li class="flex flex-wrap items-center gap-x-1.5 gap-y-0.5 text-rotulo leading-tight">
				<span class="text-faint">{fieldLabel(row.field)}:</span>
				{#if row.redacted}
					<span class="font-medium text-muted">alterado</span>
					<span class="text-meta text-faint">(valor não registrado)</span>
				{:else}
				<!-- `<del>`/`<ins>` e não dois `<span>`: o riscado e a seta são pistas VISUAIS, e um
				     leitor de tela lia "14:00 15:30" sem dizer qual é qual. Com a semântica certa,
				     ele anuncia remoção e inserção — e o `title` cobre o valor truncado. -->
				<del class="max-w-[22ch] truncate text-muted decoration-edge-strong" title={antes}>
					{antes}
				</del>
				<ArrowRight size={11} class="text-faint" aria-hidden="true" />
				<ins class="max-w-[28ch] truncate font-semibold text-ink no-underline" title={depois}>
					{depois}
				</ins>
				{/if}
			</li>
		{/each}
	</ul>
{/if}
