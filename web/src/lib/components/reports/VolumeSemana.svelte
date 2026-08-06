<script lang="ts">
	import { barPct, maxTotal, fmtWeekday, fmtDayMonth, type DayPoint } from '$lib/reports';

	// O volume de uma janela CURTA (o preset "Esta semana"), em linhas horizontais.
	//
	// Aqui o problema da barra vertical era o oposto do trimestre: seis barras num cartão de
	// ~970px davam ~145px de largura para 132px de altura — tijolos. E o calendário, que resolve o
	// trimestre, seria uma tira de seis células desperdiçando a mesma largura.
	//
	// A linha é o padrão que "Por tipo" e "Desempenho por profissional" já usam nesta tela, e tem
	// a propriedade que faltava: o número mora em TEXTO, não num `title=` que só o mouse alcança.
	let {
		porDia,
		today
	}: {
		porDia: DayPoint[];
		/** O hoje da clínica (ADR-009) — nunca o relógio do browser. */
		today: string;
	} = $props();

	const max = $derived(Math.max(1, maxTotal(porDia)));
</script>

<div class="flex flex-col gap-[11px]">
	{#each porDia as dia (dia.date)}
		{@const hoje = dia.date === today}
		{@const fechado = !dia.aberto && !dia.total}
		<div class="flex items-center gap-2.5" aria-current={hoje ? 'date' : undefined}>
			<span
				class="w-[68px] shrink-0 text-rotulo {hoje ? 'font-semibold text-accent-text' : 'text-muted'}"
			>
				<b class="font-semibold">{fmtWeekday(dia.date)}</b>
				<span class="font-mono">{fmtDayMonth(dia.date)}</span>
			</span>

			{#if fechado}
				<!-- Dia fechado não é dia de volume zero: sem esta distinção o domingo desenhava a
				     mesma barra vazia de uma segunda em que ninguém apareceu. -->
				<span class="flex-1 text-meta text-faint">clínica fechada</span>
				<span class="w-[30px] text-right font-mono text-rotulo text-faint">—</span>
			{:else}
				<div class="h-2.5 flex-1 overflow-hidden rounded-full bg-surface-2">
					<div
						class="h-full rounded-full bg-accent"
						style="width:{barPct(dia.total, max)}%"
					></div>
				</div>
				<span class="w-[30px] text-right font-mono text-rotulo font-semibold text-ink">
					{dia.total}
				</span>
			{/if}

			<span class="w-[68px] shrink-0 text-right text-meta text-faint">
				{fechado ? '' : `${dia.concluidos} concl.`}
			</span>
		</div>
	{/each}
</div>
