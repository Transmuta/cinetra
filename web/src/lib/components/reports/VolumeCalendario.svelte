<script lang="ts">
	import {
		calendarGrid,
		diaFechado,
		firstCell,
		nextCell,
		heatLevel,
		weekdayAverage,
		barPct,
		fmtDayMonth,
		WEEKDAY_LABELS,
		type DayPoint,
		type CellPos
	} from '$lib/reports';

	// O volume por dia como CALENDÁRIO (semana × dia-da-semana), e não como barras verticais.
	//
	// A barra por dia funcionava no mês (~26px cada) e desmontava no trimestre: 90 barras num
	// cartão de ~970px dão 4,8px de largura contra 6px de vão, e no celular 0,5px — um pente de
	// fios de cabelo. A célula do calendário tem tamanho fixo, então 90 dias viram 13 ou 14 colunas
	// — conforme o dia da semana em que a janela começa — e o desenho não depende mais da largura
	// disponível.
	//
	// O que o formato acrescenta, além de caber: o dia-da-semana vira uma LINHA, então "toda terça
	// cai" e "sábado rende metade" se leem de relance — a pergunta que a série de barras escondia.
	// A média por linha, à direita, é o número dessa leitura.
	let {
		porDia,
		today
	}: {
		porDia: DayPoint[];
		/** O hoje da clínica (ADR-009), para destacar a célula — nunca o relógio do browser. */
		today: string;
	} = $props();

	const grid = $derived(calendarGrid(porDia));

	// A média de cada linha — "que dia da semana rende menos", a leitura que a série de barras
	// escondia. Ela vira BARRA, e não só número, porque é ela que ocupa a largura que sobra do
	// calendário: a célula tem tamanho fixo, então num cartão largo o heatmap deixava metade do
	// espaço vazio, e a coluna da direita é o lugar natural desse peso visual.
	const medias = $derived(grid.weekdays.map((_, row) => weekdayAverage(grid.weeks.map((s) => s.days[row]))));
	const maxMedia = $derived(Math.max(0.1, ...medias.map((m) => m ?? 0)));

	// Uma parada de Tab para a grade inteira, setas para andar dentro dela (`nextCell`): 90
	// células focáveis seriam 90 paradas no caminho de quem só quer chegar ao próximo cartão.
	let foco = $state<CellPos>({ week: 0, row: 0 });
	$effect(() => {
		foco = firstCell(grid);
	});

	// O dia sob o cursor/foco, mostrado na linha de detalhe. `title=` sozinho é hover de mouse, o
	// mesmo ACC-10 que os KPIs desta tela já corrigiram: no celular ele não existe.
	let ativo = $state<DayPoint | null>(null);

	let tabela = $state<HTMLTableElement | null>(null);

	const PASSOS: Record<string, [number, number]> = {
		ArrowRight: [1, 0],
		ArrowLeft: [-1, 0],
		ArrowDown: [0, 1],
		ArrowUp: [0, -1]
	};

	function navegar(event: KeyboardEvent) {
		const passo = PASSOS[event.key];
		if (!passo) return;
		event.preventDefault();

		foco = nextCell(grid, foco, passo[0], passo[1]);
		const alvo = tabela?.querySelector<HTMLElement>(`[data-cell="${foco.week}-${foco.row}"]`);
		alvo?.focus();
	}

	const plural = (n: number, um: string, varios: string) => `${n} ${n === 1 ? um : varios}`;

	// O mesmo texto serve o nome acessível da célula e a linha de detalhe — uma frase só, para as
	// duas não divergirem.
	function resumo(dia: DayPoint): string {
		if (diaFechado(dia)) return 'clínica fechada';
		return `${plural(dia.total, 'atendimento', 'atendimentos')}, ${plural(dia.concluidos, 'concluído', 'concluídos')}`;
	}

	// A escala de intensidade sai do acento misturado com o fundo, então ela acompanha o tema
	// claro/escuro sem uma segunda paleta.
	const MISTURA = [0, 30, 55, 78, 100];

	function fundo(dia: DayPoint, max: number): string {
		const nivel = heatLevel(dia.total, max);
		if (!nivel) return 'background:var(--color-surface-2)';
		return `background:color-mix(in srgb, var(--color-accent) ${MISTURA[nivel]}%, var(--color-surface-2))`;
	}
</script>

<div class="overflow-x-auto">
	<table
		bind:this={tabela}
		class="w-full border-separate border-spacing-[3px]"
	>
		<caption class="sr-only">
			Volume de atendimentos por dia, em semanas (colunas) e dias da semana (linhas)
		</caption>
		<thead>
			<tr>
				<td></td>
				{#each grid.months as mes, i (i)}
					<th
						scope="col"
						colspan={mes.span}
						class="text-left align-bottom text-micro font-medium whitespace-nowrap text-faint"
					>
						{mes.label}
					</th>
				{/each}
				<th
					scope="col"
					colspan="2"
					class="w-full pl-3 text-left align-bottom text-micro font-medium whitespace-nowrap text-faint"
				>
					média por dia
				</th>
			</tr>
		</thead>
		<tbody>
			{#each grid.weekdays as w, row (w)}
				{@const media = medias[row]}
				<tr>
					<th scope="row" class="pr-1 text-right text-micro font-medium text-faint">
						{WEEKDAY_LABELS[w]}
					</th>
					{#each grid.weeks as semana, week (semana.start)}
						{@const dia = semana.days[row]}
						<td class="p-0">
							{#if dia}
								{@const fechado = diaFechado(dia)}
								<button
									type="button"
									data-cell="{week}-{row}"
									data-fechado={fechado}
									tabindex={foco.week === week && foco.row === row ? 0 : -1}
									aria-label="{fmtDayMonth(dia.date)}: {resumo(dia)}"
									aria-current={dia.date === today ? 'date' : undefined}
									onfocus={() => {
										foco = { week, row };
										ativo = dia;
									}}
									onblur={() => (ativo = null)}
									onmouseenter={() => (ativo = dia)}
									onmouseleave={() => (ativo = null)}
									onkeydown={navegar}
									class="grid size-[14px] place-items-center rounded-micro sm:size-[17px]"
									style="{fechado
										? 'background:transparent'
										: fundo(dia, grid.max)};{dia.date === today
										? 'outline:2px solid var(--color-accent);outline-offset:1px'
										: ''}"
								>
									<!-- Dia fechado não é dia vazio: sem expediente a célula não tem fundo, só um
									     ponto. Antes os dois eram o mesmo quadrado apagado, e os ~9 domingos de um
									     mês se liam como buraco de dado. O `data-fechado` acima é o que deixa esta
									     distinção testável sem depender de cor computada. -->
									{#if fechado}
										<span
											data-testid="ponto-fechado"
											class="size-[3px] rounded-full bg-faint"
											aria-hidden="true"
										></span>
									{/if}
								</button>
							{:else}
								<!-- Fora da janela pedida (a semana que começa antes do primeiro dia). -->
								<div class="size-[14px] sm:size-[17px]" aria-hidden="true"></div>
							{/if}
						</td>
					{/each}
					<!-- No celular a barra sai e fica só o número: ela é `w-full` e empurraria a tabela
					     para além dos 375px, criando rolagem interna que o calendário sozinho não
					     precisa (ele cabe em ~310px). -->
					<td class="hidden w-full pl-3 sm:table-cell">
						<div class="h-2 overflow-hidden rounded-full bg-surface-2">
							<div
								class="h-full rounded-full bg-accent"
								style="width:{media === null ? 0 : barPct(media, maxMedia)}%"
							></div>
						</div>
					</td>
					<td class="pl-2 text-right font-mono text-micro tabular-nums text-muted">
						{media === null ? '—' : media.toFixed(1)}
					</td>
				</tr>
			{/each}
		</tbody>
	</table>
</div>

<!-- Altura reservada: a linha troca de conteúdo a cada hover e não pode empurrar o cartão. -->
<div class="mt-2.5 flex min-h-[18px] flex-wrap items-center gap-x-4 gap-y-1 text-meta">
	{#if ativo}
		<span data-testid="volume-detalhe" class="text-ink">
			<b class="font-mono">{fmtDayMonth(ativo.date)}</b>
			· {resumo(ativo)}
		</span>
	{:else}
		<span data-testid="volume-legenda" class="inline-flex items-center gap-[5px] text-muted">
			menos
			{#each MISTURA as mistura, nivel (nivel)}
				<span
					class="size-[9px] rounded-micro"
					style={nivel
						? `background:color-mix(in srgb, var(--color-accent) ${mistura}%, var(--color-surface-2))`
						: 'background:var(--color-surface-2)'}
				></span>
			{/each}
			mais
		</span>
		<span class="inline-flex items-center gap-[5px] text-muted">
			<span class="grid size-[9px] place-items-center">
				<span class="size-[3px] rounded-full bg-faint"></span>
			</span>
			fechado
		</span>
	{/if}
</div>
