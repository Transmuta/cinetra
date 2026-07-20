// As quatro visões da agenda (doc 25 §9, Entrega 2). Tudo puro: navegação, rótulos, as
// grades de calendário e a fórmula única de ocupação (A-D12). Sem Svelte e sem DOM.
//
// O que mora aqui é o que Semana, Mês e Lista precisam para desenhar. As contagens vêm
// prontas de `GET /api/appointments/counts` — a tela nunca conta agendamento em memória,
// que é o que `renderMonth` fazia 42 vezes por render no protótipo.

import { shiftDate, dayLabel } from './agenda';

export const VIEWS = ['dia', 'semana', 'mes', 'lista'] as const;
export type AgendaView = (typeof VIEWS)[number];

export const VIEW_LABELS: Record<AgendaView, string> = {
	dia: 'Dia',
	semana: 'Semana',
	mes: 'Mês',
	lista: 'Lista'
};

export function parseView(raw: string | null | undefined): AgendaView {
	return (VIEWS as readonly string[]).includes(raw ?? '') ? (raw as AgendaView) : 'dia';
}

// ---------------------------------------------------------------------------
// Wire de `GET /api/appointments/counts`
// ---------------------------------------------------------------------------

export interface ProfessionalCount {
	professional_id: string;
	/** Agendamentos que ocupam a grade (cancelado não conta — doc 25 §7). */
	total: number;
	ocupado_minutos: number;
	/** Expediente real do profissional naquele dia, já resolvido pelas 4 camadas. */
	capacidade_minutos: number;
}

export interface DayCount {
	date: string;
	professionals: ProfessionalCount[];
}

// ---------------------------------------------------------------------------
// Navegação
// ---------------------------------------------------------------------------

const isoOf = (dt: Date) => dt.toISOString().slice(0, 10);
const parse = (date: string) => date.split('-').map(Number) as [number, number, number];

/** O passo de cada seta: ±1 dia em Dia/Lista, ±7 na Semana, ±1 mês no Mês (protótipo :1184). */
export function shiftByView(date: string, view: AgendaView, delta: number): string {
	if (view === 'semana') return shiftDate(date, delta * 7);
	if (view !== 'mes') return shiftDate(date, delta);

	const [y, m, d] = parse(date);
	// `Date.UTC(y, m, 0)` é o último dia do mês `m` (1-based) — o grampo que impede
	// 31/jan + 1 mês de virar 03/mar, como `setMonth` faz. Seta que pula um mês inteiro é
	// navegação que perde a pessoa.
	const alvo = new Date(Date.UTC(y, m - 1 + delta, 1));
	const ultimo = new Date(Date.UTC(alvo.getUTCFullYear(), alvo.getUTCMonth() + 1, 0)).getUTCDate();
	return isoOf(new Date(Date.UTC(alvo.getUTCFullYear(), alvo.getUTCMonth(), Math.min(d, ultimo))));
}

// ---------------------------------------------------------------------------
// Grades de calendário
//
// Toda a aritmética é feita em UTC de propósito: uma data "YYYY-MM-DD" aqui é um rótulo de
// calendário, não um instante. Construir com `new Date('2026-06-25')` local traria o fuso do
// processo para dentro da conta e deslocaria a grade em máquinas a oeste de Greenwich.
// ---------------------------------------------------------------------------

/** Os 7 dias da semana da data, de segunda a domingo (A-D11: 7 dias, domingo incluso). */
export function weekDays(date: string): string[] {
	const [y, m, d] = parse(date);
	const dow = new Date(Date.UTC(y, m - 1, d)).getUTCDay(); // 0 = domingo
	// Domingo (0) é o FIM da semana, não o começo: recua 6, não 0.
	const segunda = shiftDate(date, -((dow + 6) % 7));
	return Array.from({ length: 7 }, (_, i) => shiftDate(segunda, i));
}

export interface MonthCell {
	date: string;
	inMonth: boolean;
}

/**
 * A janela que o servidor precisa carregar para desenhar o mês de `date`: o **mês**, não a
 * grade.
 *
 * A grade chega a 42 células e o teto do servidor é de 31 dias — pedir a grade seria 422 em
 * todo mês que ocupa 6 linhas. As células de fora ficam sem contagem, que é como o protótipo
 * já as pintava (opacidade .5).
 *
 * Mora aqui, ao lado de `monthGrid`, porque as duas respondem à mesma pergunta — "onde começa
 * e onde termina este mês" — e estavam em arquivos diferentes: a Semana delegava a `weekDays`
 * e o Mês reimplementava `Date.UTC(y, m, 0)` à mão no `+page.server.ts`. Hoje são idênticas;
 * o custo aparece quando a fronteira mudar num lado só.
 */
export function monthWindow(date: string): { from: string; to: string } {
	const [y, m] = parse(date);
	const ultimo = new Date(Date.UTC(y, m, 0)).getUTCDate();
	const mes = date.slice(0, 7);
	return { from: `${mes}-01`, to: `${mes}-${String(ultimo).padStart(2, '0')}` };
}

/**
 * A grade do mês: semanas inteiras começando no domingo, cortadas nas linhas que o mês de
 * fato usa. Fevereiro que começa num domingo ocupa 4 linhas — desenhar 6 sempre deixaria uma
 * faixa inteira de dias de outro mês.
 */
export function monthGrid(date: string): MonthCell[] {
	const [y, m] = parse(date);
	const primeiro = new Date(Date.UTC(y, m - 1, 1));
	const startDow = primeiro.getUTCDay();
	const diasNoMes = new Date(Date.UTC(y, m, 0)).getUTCDate();
	const semanas = Math.ceil((startDow + diasNoMes) / 7);

	const inicio = isoOf(new Date(Date.UTC(y, m - 1, 1 - startDow)));
	return Array.from({ length: semanas * 7 }, (_, i) => {
		const d = shiftDate(inicio, i);
		return { date: d, inMonth: Number(d.slice(5, 7)) === m };
	});
}

// ---------------------------------------------------------------------------
// Rótulo contextual
// ---------------------------------------------------------------------------

// Só o mês. `{day, month}` junto devolve "22 de jun." em pt-BR, e o "de" no meio de um
// intervalo ("22 de jun. – 28 de jun.") ocupa o dobro do espaço na barra sem informar nada.
const MES_CURTO = new Intl.DateTimeFormat('pt-BR', {
	month: 'short',
	timeZone: 'UTC'
});
const MES_ANO = new Intl.DateTimeFormat('pt-BR', {
	month: 'long',
	year: 'numeric',
	timeZone: 'UTC'
});

const noon = (date: string) => new Date(`${date}T12:00:00Z`);

/** "22 jun." — dia sem zero à esquerda, como o rótulo do protótipo (:1510). */
const diaMes = (date: string) => `${Number(date.slice(8, 10))} ${MES_CURTO.format(noon(date))}`;

/** "quinta-feira, 25 de junho" · "22 jun. – 28 jun." · "junho de 2026", com " · hoje". */
export function viewLabel(date: string, today: string, view: AgendaView): string {
	if (view === 'dia' || view === 'lista') return dayLabel(date, today);

	if (view === 'semana') {
		const dias = weekDays(date);
		const label = `${diaMes(dias[0])} – ${diaMes(dias[6])}`;
		// O sufixo marca o intervalo que CONTÉM hoje. O protótipo comparava a data exata, e
		// assim a semana corrente perdia a marca em todo dia que não fosse o de hoje.
		return dias.includes(today) ? `${label} · hoje` : label;
	}

	const label = MES_ANO.format(noon(date));
	return today.slice(0, 7) === date.slice(0, 7) ? `${label} · hoje` : label;
}

// ---------------------------------------------------------------------------
// Ocupação — a fórmula única (A-D12)
//
// minutos ocupados ÷ minutos de expediente real, em todos os lugares, SEM clamp. O protótipo
// dava três respostas para a mesma pergunta (540 min fixos, expediente real, e "9 por
// profissional"), e grampeava em 100% — escondendo justamente o dia sobrecarregado.
// ---------------------------------------------------------------------------

/** `null` = não há expediente. Dia fechado não é dia com 0% de ocupação. */
export function occupancyRate(ocupado: number, capacidade: number): number | null {
	return capacidade > 0 ? ocupado / capacidade : null;
}

export type OccupancyTone = 'closed' | 'empty' | 'normal' | 'over';

export function occupancyTone(rate: number | null): OccupancyTone {
	if (rate === null) return 'closed';
	if (rate === 0) return 'empty';
	return rate > 1 ? 'over' : 'normal';
}

export interface DayTotal {
	date: string;
	total: number;
	ocupado_minutos: number;
	capacidade_minutos: number;
	rate: number | null;
}

/**
 * Achata as contagens por-profissional em totais de dia, respeitando o toggle da sidebar.
 *
 * O recorte é aplicado no numerador **e** no denominador: ocultar um profissional tira os
 * agendamentos dele e o expediente dele. Somar só de um lado produziria uma barra que muda
 * de tamanho quando ninguém mudou de agenda.
 */
export function dayTotals(days: DayCount[], hidden: string[]): DayTotal[] {
	const oculto = new Set(hidden);

	return days.map((day) => {
		const visiveis = day.professionals.filter((p) => !oculto.has(p.professional_id));
		const soma = (pick: (p: ProfessionalCount) => number) =>
			visiveis.reduce((acc, p) => acc + pick(p), 0);

		const ocupado_minutos = soma((p) => p.ocupado_minutos);
		const capacidade_minutos = soma((p) => p.capacidade_minutos);

		return {
			date: day.date,
			total: soma((p) => p.total),
			ocupado_minutos,
			capacidade_minutos,
			rate: occupancyRate(ocupado_minutos, capacidade_minutos)
		};
	});
}
