import { weekDays, monthWindow } from './agenda-views';

// Domínio da tela de Relatórios (doc 33, Fatia 9). Só lógica pura — parsing dos filtros da URL,
// a janela de cada preset de período e os cálculos de proporção das barras. O componente e o
// `+page.server.ts` importam daqui; nada de fetch nem de DOM.

export const PERIODS = ['hoje', 'semana', 'mes'] as const;
export type Period = (typeof PERIODS)[number];

export const PERIOD_LABELS: Record<Period, string> = {
	hoje: 'Hoje',
	semana: 'Esta semana',
	mes: 'Este mês'
};

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

// O gráfico de volume é POR DIA quando a janela tem mais de um dia; num dia só ele degenera e a
// tela mostra "por profissional" (`showDaily` do protótipo, [:3386]).
export function showDaily(porDia: DayPoint[]): boolean {
	return porDia.length > 1;
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
