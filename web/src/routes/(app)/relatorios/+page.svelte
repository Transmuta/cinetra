<script lang="ts">
	import CalendarDays from '@lucide/svelte/icons/calendar-days';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import TrendingDown from '@lucide/svelte/icons/trending-down';
	import CircleX from '@lucide/svelte/icons/circle-x';
	import Gauge from '@lucide/svelte/icons/gauge';
	import Info from '@lucide/svelte/icons/info';
	import Modal from '$lib/components/Modal.svelte';
	import VolumeCalendario from '$lib/components/reports/VolumeCalendario.svelte';
	import VolumeSemana from '$lib/components/reports/VolumeSemana.svelte';
	import { avatarColor, avatarStyle } from '$lib/avatar';
	import { initials } from '$lib/format';
	import { todayInZone } from '$lib/agenda';
	import {
		PERIOD_LABELS,
		professionalName,
		professionalById,
		typeById,
		barPct,
		sharePct,
		maxTotal,
		volumeMode,
		fmtDayMonth,
		rangeLabel
	} from '$lib/reports';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	const report = $derived(data.report);
	const t = $derived(report.totals);
	const profs = $derived(report.professionals);
	const types = $derived(report.appointment_types);

	// O "hoje" da clínica sai do relógio que veio NA RESPOSTA (ADR-009), para realçar a barra de
	// hoje no gráfico — nunca do relógio do browser.
	const today = $derived(todayInZone(report.agora, report.timezone));

	const profNome = $derived(
		data.prof === 'todos'
			? 'Todos os profissionais'
			: professionalName(profs, data.prof)
	);
	const rangeLbl = $derived(rangeLabel(report.range));

	// Qual desenho a janela pede (doc 106): um dia degenera em "por profissional", a semana vira
	// linhas por dia e o mês/trimestre vira calendário. A barra vertical servia os três e
	// desmontava nos extremos — 145px de largura na semana, 4,8px no trimestre.
	const modo = $derived(volumeMode(report.por_dia));
	const daily = $derived(modo !== 'profissional');
	const maxTipo = $derived(Math.max(1, maxTotal(report.por_tipo)));
	const maxProf = $derived(Math.max(1, maxTotal(report.por_profissional)));

	// A soma das quatro faixas de status — o denominador da "Composição por status" (pode diferir
	// de `atendimentos`, que exclui cancelados).
	const totStatus = $derived(t.concluidos + t.futuros + t.faltas + t.cancelados || 1);

	// ACC-10 (doc 83): a fórmula chegava por `title=` — hover de mouse, que no celular não
	// existe. Quem abre o relatório no telefone é justamente quem cobra o número. O clique no
	// ícone guarda aqui o KPI escolhido e o `Modal` (foco, Esc e clique-fora já resolvidos)
	// mostra a conta; `null` é "nenhum aberto".
	let explicando = $state<{ label: string; formula: string } | null>(null);

	const statusRows = $derived([
		{ label: 'Concluídos', n: t.concluidos, color: 'var(--color-success)' },
		{ label: 'Agendados', n: t.futuros, color: 'var(--color-info)' },
		{ label: 'Faltas', n: t.faltas, color: 'var(--color-danger)' },
		{ label: 'Cancelados', n: t.cancelados, color: 'var(--color-faint)' }
	]);
</script>

<svelte:head><title>Relatórios · Cinetra</title></svelte:head>

<div class="w-full p-4 md:px-[18px] md:py-4">
	<!-- Cabeçalho: período, intervalo, profissional e o pico do período. -->
	<div class="mb-3.5 flex flex-wrap items-center gap-2">
		<span
			class="rounded-full bg-accent-subtle px-2.5 py-1 text-rotulo font-semibold text-accent-text"
		>
			{PERIOD_LABELS[data.period]}
		</span>
		<span class="font-mono text-rotulo text-muted">{rangeLbl}</span>
		<span class="text-rotulo text-faint">·</span>
		<span class="text-rotulo text-muted">{profNome}</span>
		{#if t.pico && daily}
			<span class="ml-auto text-rotulo text-faint">
				Pico: <b class="text-ink">{fmtDayMonth(t.pico.date)}</b> ({t.pico.total})
			</span>
		{/if}
	</div>

	<!-- 5 KPIs -->
	<div class="mb-3.5 flex flex-wrap gap-[11px]">
		{#snippet kpi(
			label: string,
			val: string,
			sub: string,
			color: string,
			Icon: typeof CalendarDays,
			formula: string
		)}
			<!-- HOM-021: o número aparecia sem a conta que o produz, e duas destas contas não são
			     adivinháveis — a taxa de falta NÃO divide pelo total, e a ocupação é grampeada em
			     100%. Sem a fórmula à mão, a primeira reação de quem gerencia é contestar o
			     número; com ela, a conversa passa a ser sobre a operação. A fórmula sai daqui
			     igual à do servidor (`summary_totais/5`), e é por isso que ela é literal.
			     O `title` continua servindo o hover do mouse; o botão ao lado é o caminho que
			     funciona no toque, no Tab e no leitor de tela (ACC-10). -->
			<div
				title={formula}
				class="min-w-[150px] flex-[1_1_150px] rounded-cartao border border-edge bg-surface px-[15px] py-3.5"
			>
				<div class="mb-[7px] flex items-center gap-[7px] text-meta text-muted">
					<span style="color:{color}"><Icon size={14} /></span>
					{label}
					<!-- 24px de alvo (WCAG 2.5.8) sem crescer a linha: a margem negativa devolve o
					     espaço que o quadrado tomaria. -->
					<button
						type="button"
						onclick={() => (explicando = { label, formula })}
						aria-haspopup="dialog"
						aria-label="Como {label} é calculado"
						class="-my-1 -mr-1 ml-auto grid size-6 place-items-center rounded-controle text-faint hover:bg-surface-2 hover:text-muted"
					>
						<Info size={12} />
					</button>
				</div>
				<div class="font-mono text-destaque font-semibold tabular-nums" style="color:{color}">
					{val}
				</div>
				<div class="mt-0.5 text-meta text-faint">{sub}</div>
			</div>
		{/snippet}

		{@render kpi(
			'Atendimentos',
			String(t.atendimentos),
			`${t.futuros} ainda agendados`,
			'var(--color-ink)',
			CalendarDays,
			'Pessoas atendidas no período, exceto as de sessões canceladas — numa turma cada participante conta um. Inclui as que ainda vão acontecer.'
		)}
		{@render kpi(
			'Concluídos',
			String(t.concluidos),
			t.atendimentos ? `${sharePct(t.concluidos, t.atendimentos)}% do volume` : '—',
			'var(--color-success)',
			CircleCheck,
			'Participantes marcados como presentes. Numa turma de 2 em que um veio e o outro faltou, conta 1 aqui e 1 na taxa de falta.'
		)}
		{@render kpi(
			'Taxa de falta',
			`${t.taxa_falta}%`,
			`${t.faltas} faltas`,
			t.taxa_falta > 20 ? 'var(--color-danger)' : 'var(--color-warning)',
			TrendingDown,
			'Faltas ÷ (concluídos + faltas), contadas por participante — só entram as presenças que já fecharam. O que ainda vai acontecer não conta, nem no numerador nem no denominador.'
		)}
		{@render kpi(
			'Cancelamentos',
			String(t.cancelados),
			'no período',
			'var(--color-faint)',
			CircleX,
			'Sessões canceladas no período — aqui a conta é de BLOCOS, não de pessoas: cancelar é ato de agendamento, não desfecho de presença. Não entram na conta de atendimentos nem na de ocupação.'
		)}
		{@render kpi(
			'Ocupação',
			`${t.ocupacao}%`,
			`${t.dias_uteis} dias úteis`,
			t.ocupacao >= 70 ? 'var(--color-success)' : 'var(--color-info)',
			Gauge,
			`Minutos ocupados ÷ minutos de expediente (${t.ocupado_minutos} de ${t.capacidade_minutos} min). Não é "sessões ÷ vagas": uma sessão de 50 min pesa mais que uma de 30. Passando de 100% o valor é exibido como 100%.`
		)}
	</div>

	<!-- Volume: calendário (mês/trimestre), linhas por dia (semana) ou por profissional (dia único) -->
	<div class="mb-3.5 overflow-hidden rounded-cartao border border-edge bg-surface">
		<div class="flex items-center justify-between gap-2.5 border-b border-edge px-4 py-[13px]">
			<!-- `h2` como os outros títulos de cartão (ACC-22): a hierarquia já era visual. -->
			<h2 class="text-leitura font-semibold">
				{daily ? 'Volume por dia' : 'Volume por profissional'}
			</h2>
			{#if daily}
				<span class="text-meta text-faint">{t.atendimentos} atendimentos</span>
			{/if}
		</div>
		<div class="px-4 py-3.5">
			{#if modo === 'calendario'}
				<VolumeCalendario porDia={report.por_dia} {today} />
			{:else if modo === 'semana'}
				<VolumeSemana porDia={report.por_dia} {today} />
			{:else}
				<div class="flex flex-col gap-[11px]">
					{#each report.por_profissional as pp (pp.professional_id)}
						{@const prof = professionalById(profs, pp.professional_id)}
						<div class="flex items-center gap-2.5">
							<span
								class="grid size-[26px] shrink-0 place-items-center rounded-full text-micro font-semibold"
								style={avatarStyle(prof?.cor_indice ?? 1)}
							>
								{initials(prof?.nome ?? '—')}
							</span>
							<span class="w-[120px] truncate text-rotulo font-medium">
								{professionalName(profs, pp.professional_id)}
							</span>
							<div class="h-2.5 flex-1 overflow-hidden rounded-full bg-surface-2">
								<div
									class="h-full"
									style="width:{barPct(pp.total, maxProf)}%;background:{avatarColor(
										prof?.cor_indice ?? 1
									)}"
								></div>
							</div>
							<span class="w-[26px] text-right font-mono text-rotulo text-muted">{pp.total}</span>
						</div>
					{/each}
				</div>
			{/if}
		</div>
	</div>

	<!-- Por tipo | Composição por status -->
	<div class="mb-3.5 grid gap-3.5 md:grid-cols-2">
		<div class="overflow-hidden rounded-cartao border border-edge bg-surface">
			<h2 class="border-b border-edge px-4 py-[13px] text-leitura font-semibold">
				Por tipo de atendimento
			</h2>
			<div class="px-4 py-3.5">
				{#if report.por_tipo.length}
					<div class="flex flex-col gap-3">
						{#each report.por_tipo as row (row.appointment_type_id)}
							{@const tipo = typeById(types, row.appointment_type_id)}
							<div>
								<div class="mb-[5px] flex items-center gap-2">
									<span
										class="size-[9px] shrink-0 rounded-controle"
										style="background:{tipo?.cor ?? 'var(--color-faint)'}"
									></span>
									<span class="min-w-0 flex-1 truncate text-rotulo font-medium">
										{tipo?.nome ?? '—'}
									</span>
									<span class="font-mono text-rotulo text-muted">{row.total}</span>
									<span class="w-[38px] text-right text-meta text-faint">
										{sharePct(row.total, t.atendimentos)}%
									</span>
								</div>
								<div class="h-[7px] overflow-hidden rounded-micro bg-surface-2">
									<div
										class="h-full opacity-85"
										style="width:{barPct(row.total, maxTipo)}%;background:{tipo?.cor ??
											'var(--color-faint)'}"
									></div>
								</div>
							</div>
						{/each}
					</div>
				{:else}
					<div class="py-2 text-corpo text-faint">Sem dados no período.</div>
				{/if}
			</div>
		</div>

		<div class="overflow-hidden rounded-cartao border border-edge bg-surface">
			<h2 class="border-b border-edge px-4 py-[13px] text-leitura font-semibold">
				Composição por status
			</h2>
			<div class="px-4 py-3.5">
				<div class="flex flex-col gap-3">
					{#each statusRows as row (row.label)}
						<div class="flex items-center gap-2.5">
							<span class="w-24 text-rotulo text-muted">{row.label}</span>
							<div class="h-[9px] flex-1 overflow-hidden rounded-full bg-surface-2">
								<div
									class="h-full"
									style="width:{barPct(row.n, totStatus)}%;background:{row.color}"
								></div>
							</div>
							<span class="w-[34px] text-right font-mono text-rotulo text-ink">{row.n}</span>
						</div>
					{/each}
				</div>
			</div>
		</div>
	</div>

	<!-- Desempenho por profissional -->
	<div class="overflow-hidden rounded-cartao border border-edge bg-surface">
		<h2 class="border-b border-edge px-4 py-[13px] text-leitura font-semibold">
			Desempenho por profissional
		</h2>
		<div>
			<div
				class="hidden grid-cols-[1.8fr_0.9fr_0.8fr_1.1fr] gap-2.5 px-4 pb-2 pt-3 text-meta font-semibold text-faint sm:grid"
			>
				<span>Profissional</span>
				<span class="text-right">Volume</span>
				<span class="text-right">Faltas</span>
				<span class="text-right">Taxa falta</span>
			</div>
			{#each report.por_profissional as pp (pp.professional_id)}
				{@const prof = professionalById(profs, pp.professional_id)}
				<div
					class="grid grid-cols-[1fr_auto] items-center gap-2.5 border-t border-edge px-4 py-[11px] sm:grid-cols-[1.8fr_0.9fr_0.8fr_1.1fr]"
				>
					<span class="flex min-w-0 items-center gap-2.5">
						<span
							class="grid size-7 shrink-0 place-items-center rounded-full text-micro font-semibold"
							style={avatarStyle(prof?.cor_indice ?? 1)}
						>
							{initials(prof?.nome ?? '—')}
						</span>
						<span class="truncate text-corpo font-semibold">
							{professionalName(profs, pp.professional_id)}
						</span>
					</span>
					<span
						class="text-right font-mono text-corpo font-semibold sm:order-none"
						title="Volume"
					>
						{pp.total}
					</span>
					<span class="hidden text-right font-mono text-rotulo text-muted sm:block">
						{pp.faltas}
					</span>
					<span class="hidden text-right sm:block">
						<span class="inline-flex items-center justify-end gap-1.5">
							<span class="inline-block h-[7px] w-11 overflow-hidden rounded-micro bg-surface-2">
								<span
									class="block h-full"
									style="width:{pp.taxa_falta}%;background:{pp.taxa_falta > 20
										? 'var(--color-danger)'
										: 'var(--color-warning)'}"
								></span>
							</span>
							<span
								class="w-[30px] text-right font-mono text-rotulo"
								style="color:{pp.taxa_falta > 20 ? 'var(--color-danger)' : 'var(--color-muted)'}"
							>
								{pp.taxa_falta}%
							</span>
						</span>
					</span>
				</div>
			{/each}
			{#if !report.por_profissional.length}
				<div class="border-t border-edge px-4 py-4 text-corpo text-faint">Sem dados no período.</div>
			{/if}
		</div>
	</div>
</div>

{#if explicando}
	<Modal title="Como calculamos: {explicando.label}" onClose={() => (explicando = null)}>
		<p class="text-corpo leading-relaxed text-ink">{explicando.formula}</p>
	</Modal>
{/if}
