import { weekDays, monthWindow } from './agenda-views';
import { shiftDate } from './agenda';

// Domínio da tela de Relatórios (doc 33, Fatia 9). Só lógica pura — parsing dos filtros da URL,
// a janela de cada preset de período e os cálculos de proporção das barras. O componente e o
// `+page.server.ts` importam daqui; nada de fetch nem de DOM.

export const PERIODS = ['hoje', 'semana', 'mes', 'trimestre'] as const;
export type Period = (typeof PERIODS)[number];

export const PERIOD_LABELS: Record<Period, string> = {
	hoje: 'Hoje',
	semana: 'Esta semana',
	mes: 'Este mês',
	trimestre: 'Últimos 90 dias'
};

// O trimestre é uma janela MÓVEL — 90 dias corridos terminando hoje, não o trimestre civil.
// `-89` porque `hoje` já é um dos 90 dias.
const TRIMESTRE_DIAS = 90;

// `?period=` fora do conjunto cai em 'mes' — o mesmo default do protótipo (`repPeriodo:'mes'`).
export function parsePeriod(raw: string | null | undefined): Period {
	return PERIODS.includes(raw as Period) ? (raw as Period) : 'mes';
}

export interface ReportRange {
	from: string;
	to: string;
}

// A janela que cada preset pede ao servidor, ancorada em `today` (o hoje da clínica). Semana é
// segunda–sábado (o protótipo pula o domingo, `mon+5`); mês é o mês corrente inteiro.
export function periodWindow(period: Period, today: string): ReportRange {
	if (period === 'hoje') return { from: today, to: today };
	if (period === 'semana') {
		const dias = weekDays(today);
		return { from: dias[0], to: dias[5] };
	}
	if (period === 'trimestre') {
		return { from: shiftDate(today, -(TRIMESTRE_DIAS - 1)), to: today };
	}
	return monthWindow(today);
}

export interface ReportPico {
	date: string;
	total: number;
}

export interface ReportTotals {
	atendimentos: number;
	concluidos: number;
	faltas: number;
	cancelados: number;
	futuros: number;
	taxa_falta: number;
	ocupacao: number;
	ocupado_minutos: number;
	capacidade_minutos: number;
	dias_uteis: number;
	pico: ReportPico | null;
}

export interface DayPoint {
	date: string;
	total: number;
	concluidos: number;
	// Havia expediente nesse dia para o escopo selecionado (o mesmo denominador da ocupação).
	// Sem isso "clínica fechada" e "dia aberto sem ninguém" são a mesma célula vazia no gráfico,
	// e ~9 domingos por mês passam a se ler como buraco de dado.
	aberto: boolean;
}

export interface TypePoint {
	appointment_type_id: string;
	total: number;
}

export interface ProfPoint {
	professional_id: string;
	total: number;
	concluidos: number;
	faltas: number;
	taxa_falta: number;
}

export interface ReportProfessional {
	id: string;
	nome: string;
	cor_indice: number;
}

export interface ReportType {
	id: string;
	nome: string;
	cor: string;
}

export interface ReportsData {
	range: ReportRange;
	totals: ReportTotals;
	por_dia: DayPoint[];
	por_tipo: TypePoint[];
	por_profissional: ProfPoint[];
	professionals: ReportProfessional[];
	appointment_types: ReportType[];
	agora: string;
	timezone: string;
}

// O nome do profissional para a barra/tabela, pelo id — sem o "Dr(a). " que a sidebar do
// protótipo remove. Cai num traço se o id não estiver na lista (não deveria acontecer).
export function professionalName(profs: ReportProfessional[], id: string): string {
	const prof = profs.find((p) => p.id === id);
	if (!prof) return '—';
	return prof.nome.replace(/^Dr[a]?\.\s*/, '');
}

export function professionalById(
	profs: ReportProfessional[],
	id: string
): ReportProfessional | undefined {
	return profs.find((p) => p.id === id);
}

export function typeById(types: ReportType[], id: string): ReportType | undefined {
	return types.find((t) => t.id === id);
}

// Proporção 0–100 de uma barra contra o MAIOR valor da série (comprimento relativo). Max 0 → 0,
// sem divisão por zero.
export function barPct(value: number, max: number): number {
	if (max <= 0) return 0;
	return Math.round((value / max) * 100);
}

// A FATIA que um valor representa do total (o "%" ao lado da contagem por tipo). Total 0 → 0.
export function sharePct(value: number, total: number): number {
	if (total <= 0) return 0;
	return Math.round((value / total) * 100);
}

// O maior `total` de uma série — o denominador de `barPct`. Vazio → 0.
export function maxTotal<T extends { total: number }>(items: T[]): number {
	return items.reduce((max, item) => Math.max(max, item.total), 0);
}

// ---------------------------------------------------------------------------
// Volume por dia — qual desenho a janela pede
// ---------------------------------------------------------------------------

export type VolumeMode = 'profissional' | 'semana' | 'calendario';

// Acima daqui a barra por dia deixa de caber. Aritmética do cartão (~970px no desktop, gap de
// 6px): 30 barras dão ~26px cada e ainda funcionam; 90 dão **4,8px** — vão maior que a barra —,
// e no celular (~310px, gap 3px) dão 0,5px, o pente de fios de cabelo que motivou esta troca.
// O calendário não tem esse problema: a célula é de tamanho fixo e 90 dias viram 13 colunas.
const MAX_DIAS_EM_BARRAS = 8;

/**
 * O desenho que a janela pede:
 *
 *   * `profissional` — um dia só; "por dia" degenera numa barra e a tela mostra a quebra por
 *     profissional (o `showDaily` do protótipo, [:3386]);
 *   * `semana` — janela curta (o preset "Esta semana"): barras horizontais com o nome do dia,
 *     no mesmo padrão de linha de "Por tipo" e "Desempenho por profissional";
 *   * `calendario` — mês e trimestre: heatmap semana × dia-da-semana.
 */
export function volumeMode(porDia: DayPoint[]): VolumeMode {
	if (porDia.length <= 1) return 'profissional';
	return porDia.length <= MAX_DIAS_EM_BARRAS ? 'semana' : 'calendario';
}

// ---------------------------------------------------------------------------
// A grade do calendário
// ---------------------------------------------------------------------------

/** 0 = segunda … 6 = domingo. Em UTC: a data já é local, e `new Date('YYYY-MM-DD')` no fuso do
 * browser recua um dia a oeste de Greenwich — o que trocaria a coluna da célula. */
export function weekdayIndex(iso: string): number {
	const [y, m, d] = iso.split('-').map(Number);
	// `getUTCDay` é 0 = domingo; a grade começa na segunda, então domingo vira 6.
	return (new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 6) % 7;
}

/** A segunda-feira da semana de `iso` — a chave da coluna. */
export function weekStart(iso: string): string {
	return shiftDate(iso, -weekdayIndex(iso));
}

export interface CalendarWeek {
	/** A segunda da semana, mesmo quando ela cai antes do começo da janela. */
	start: string;
	/** Alinhado a `weekdays`; `null` é dia FORA da janela — diferente de dia fechado. */
	days: (DayPoint | null)[];
}

export interface CalendarMonth {
	label: string;
	/** Quantas colunas de semana este mês ocupa. */
	span: number;
}

export interface CalendarGrid {
	/** As linhas presentes, em ordem seg→dom. */
	weekdays: number[];
	weeks: CalendarWeek[];
	months: CalendarMonth[];
	/** O maior total da janela — o denominador de `heatLevel`. */
	max: number;
}

const MES_CURTO = new Intl.DateTimeFormat('pt-BR', { month: 'short', timeZone: 'UTC' });

// "jun" — pt-BR devolve "jun." e o ponto não paga o pixel num cabeçalho de 13 colunas.
function monthShort(iso: string): string {
	const [y, m, d] = iso.split('-').map(Number);
	return MES_CURTO.format(new Date(Date.UTC(y, m - 1, d))).replace('.', '');
}

/**
 * A janela empilhada em colunas de semana × linhas de dia-da-semana — o heatmap de volume.
 *
 * Só entram as linhas que a janela de fato usa: um dia-da-semana em que a clínica nunca abre e
 * nunca teve atendimento não vira uma faixa vazia atravessando o gráfico (é o caso do domingo,
 * fechado no seed). A clínica sem expediente nenhum é a exceção — ali todas as linhas da janela
 * ficam, porque esconder tudo seria pior que mostrar zeros.
 */
export function calendarGrid(porDia: DayPoint[]): CalendarGrid {
	if (!porDia.length) return { weekdays: [], weeks: [], months: [], max: 0 };

	const usados = new Set(porDia.map((d) => weekdayIndex(d.date)));
	const relevantes = new Set(
		porDia.filter((d) => d.aberto || d.total > 0).map((d) => weekdayIndex(d.date))
	);
	const linhas = relevantes.size ? relevantes : usados;
	const weekdays = [0, 1, 2, 3, 4, 5, 6].filter((w) => linhas.has(w));

	const porData = new Map(porDia.map((d) => [d.date, d]));
	const starts = [...new Set(porDia.map((d) => weekStart(d.date)))].sort();

	// A semana que não tem NENHUMA célula visível não vira coluna. Ela aparece quando a janela
	// começa (ou termina) num dia-da-semana que virou linha escondida: `mes` de agosto/2026 abre
	// num sábado, e para a clínica seg–sex essa primeira coluna ficaria inteira vazia. Além de ser
	// um vão sem leitura, ela quebrava `monthSpans`, que lê o mês do primeiro dia da coluna.
	const weeks = starts
		.map((start) => ({
			start,
			days: weekdays.map((w) => porData.get(shiftDate(start, w)) ?? null)
		}))
		.filter((semana) => semana.days.some((d) => d !== null));

	return { weekdays, weeks, months: monthSpans(weeks), max: maxTotal(porDia) };
}

// O cabeçalho de meses: uma faixa por mês, do tamanho do bloco de semanas que ele ocupa. O mês de
// uma coluna é o do PRIMEIRO dia dela dentro da janela — a semana da virada (25/05–31/05) fica em
// maio, e não em junho, que é como o calendário se lê.
function monthSpans(weeks: CalendarWeek[]): CalendarMonth[] {
	const chaves = weeks.map((w) => (w.days.find((d) => d !== null) as DayPoint).date.slice(0, 7));
	// Ano no rótulo só quando a janela cruza a virada — "dez" e "jan" soltos não dizem qual é qual.
	const cruzaAno = new Set(chaves.map((c) => c.slice(0, 4))).size > 1;

	return chaves.reduce<CalendarMonth[]>((acc, chave, i) => {
		if (i > 0 && chave === chaves[i - 1]) {
			acc[acc.length - 1].span += 1;
			return acc;
		}
		const nome = monthShort(`${chave}-01`);
		acc.push({ label: cruzaAno ? `${nome}/${chave.slice(2, 4)}` : nome, span: 1 });
		return acc;
	}, []);
}

export interface CellPos {
	week: number;
	row: number;
}

/** A primeira célula que existe, em ordem de leitura — onde o foco pousa. */
export function firstCell(grid: CalendarGrid): CellPos {
	for (let row = 0; row < grid.weekdays.length; row++) {
		const week = grid.weeks.findIndex((w) => w.days[row] !== null);
		if (week >= 0) return { week, row };
	}
	return { week: 0, row: 0 };
}

/**
 * O passo do foco na grade (setas do teclado), pulando os buracos: uma janela que começa numa
 * quarta não tem célula de segunda, e parar num buraco perderia o foco.
 *
 * É o que permite a grade inteira ter **uma** parada de Tab em vez de 90 — o dia fechado
 * continua focável, porque "fechado" é informação que o leitor de tela precisa ouvir.
 */
export function nextCell(grid: CalendarGrid, from: CellPos, dWeek: number, dRow: number): CellPos {
	let { week, row } = from;

	for (;;) {
		week += dWeek;
		row += dRow;
		if (week < 0 || week >= grid.weeks.length || row < 0 || row >= grid.weekdays.length) {
			return from;
		}
		if (grid.weeks[week].days[row] !== null) return { week, row };
	}
}

const NIVEIS = 4;

/**
 * A intensidade da célula, 0–4, repartida contra o maior dia da janela. Nível 0 é reservado ao
 * dia sem nenhum atendimento: um único atendimento numa janela movimentada ainda pinta 1, senão
 * ele desapareceria dentro do fundo e o gráfico mentiria por arredondamento.
 */
export function heatLevel(total: number, max: number): number {
	if (total <= 0 || max <= 0) return 0;
	return Math.min(NIVEIS, Math.max(1, Math.ceil((total / max) * NIVEIS)));
}

/**
 * A média de atendimentos de uma LINHA do calendário (um dia da semana ao longo da janela) — o
 * número que responde "que dia é fraco", que 90 barras verticais escondiam.
 *
 * O denominador são os dias **abertos**: contar o feriado e o sábado fechado puxaria a média do
 * sábado para baixo e diria que ele rende menos do que rende. `null` quando a linha nunca abriu.
 */
export function weekdayAverage(days: (DayPoint | null)[]): number | null {
	const abertos = days.filter((d): d is DayPoint => d !== null && d.aberto);
	if (!abertos.length) return null;
	const soma = abertos.reduce((acc, d) => acc + d.total, 0);
	return Math.round((soma / abertos.length) * 10) / 10;
}

// Os rótulos das linhas do calendário e das barras da semana, na ordem de `weekdayIndex`.
export const WEEKDAY_LABELS = ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'] as const;

/** "seg" · "sáb" — o dia da semana da data, para o rótulo da linha/barra. */
export function fmtWeekday(iso: string): string {
	return WEEKDAY_LABELS[weekdayIndex(iso)];
}

// DD/MM a partir de um ISO `YYYY-MM-DD`, sem `Date` (fuso não entra: a data já é local).
export function fmtDayMonth(iso: string): string {
	const [, m, d] = iso.split('-');
	return `${d}/${m}`;
}

// O rótulo do intervalo no cabeçalho: um dia só mostra a data; janela mostra "de – até".
export function rangeLabel(range: ReportRange): string {
	return range.from === range.to
		? fmtDayMonth(range.from)
		: `${fmtDayMonth(range.from)} – ${fmtDayMonth(range.to)}`;
}
