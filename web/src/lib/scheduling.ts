// Tipos e regras puras das telas de Horário e Exceções (doc 22). Espelha os helpers do
// protótipo (`periodEditor` :3198, `cfgHorario` :3239, `cfgFeriados` :3266). A autoridade real
// dos períodos é o servidor (`Api.Scheduling.Periods`); aqui é UX — oferecer/ordenar/formatar.
import { canManageMembers, type Papel } from './session';

// Um período é o par [início, fim] em "HH:MM"; um dia é uma lista de períodos; [] = fechado.
export type Period = [string, string];
export type WeekHours = Record<string, Period[]>;

export type ExceptionKind = 'fechado' | 'horario';

export interface ClinicException {
	id: string;
	data: string; // ISO "YYYY-MM-DD"
	nome: string | null;
	tipo: ExceptionKind;
	periods: Period[];
}

// Ordem de exibição do protótipo (`cfgHorario` :3247): Segunda → Sábado, Domingo por último.
export const WEEKDAYS: ReadonlyArray<{ dow: number; label: string }> = [
	{ dow: 1, label: 'Segunda' },
	{ dow: 2, label: 'Terça' },
	{ dow: 3, label: 'Quarta' },
	{ dow: 4, label: 'Quinta' },
	{ dow: 5, label: 'Sexta' },
	{ dow: 6, label: 'Sábado' },
	{ dow: 0, label: 'Domingo' }
];

// Ao abrir um dia fechado, o protótipo preenche manhã e tarde (`toggle` :3245).
export function defaultDayPeriods(): Period[] {
	return [
		['08:00', '12:00'],
		['13:00', '18:00']
	];
}

// "+ período" (:3210): parte do fim do último período; se já passou das 18h, sugere 19h.
export function appendPeriod(periods: Period[]): Period[] {
	const last = periods.length ? periods[periods.length - 1][1] : '13:00';
	const end = last < '18:00' ? '18:00' : '19:00';
	return [...periods, [last, end]];
}

export function setPeriodTime(periods: Period[], index: number, side: 0 | 1, value: string): Period[] {
	return periods.map((p, i): Period => {
		if (i !== index) return p;
		return side === 0 ? [value, p[1]] : [p[0], value];
	});
}

export function removePeriod(periods: Period[], index: number): Period[] {
	return periods.filter((_, i) => i !== index);
}

// Espelhar Seg → Seg–Sex (:3249): copia o horário de segunda para os dias úteis 2..5.
export function mirrorWeekdays(week: WeekHours): WeekHours {
	const ref = week['1'] ?? defaultDayPeriods();
	const next = { ...week };
	for (const dow of [1, 2, 3, 4, 5]) next[String(dow)] = ref.map((p): Period => [p[0], p[1]]);
	return next;
}

// A semana mudou em relação ao salvo? (banner "Alterações não salvas", :3266). Compara os 7
// dias por valor — key order não importa.
export function weekChanged(draft: WeekHours, saved: WeekHours): boolean {
	return WEEKDAYS.some(({ dow }) => {
		const k = String(dow);
		return JSON.stringify(draft[k] ?? []) !== JSON.stringify(saved[k] ?? []);
	});
}

// "08:00–12:00, 13:00–18:00", ou "Fechado" quando não há período (lista da tela e resumo).
export function formatPeriods(periods: Period[]): string {
	if (!periods || periods.length === 0) return 'Fechado';
	return periods.map(([i, f]) => `${i}–${f}`).join(', ');
}

// Data ISO → "09/07/2026" no fuso local. O `T00:00` evita o recuo de um dia que `new
// Date("2026-07-09")` (UTC) causa a oeste de Greenwich.
export function formatDate(iso: string): string {
	const d = new Date(`${iso}T00:00`);
	if (Number.isNaN(d.getTime())) return iso;
	return d.toLocaleDateString('pt-BR');
}

// Gestão do horário/exceções = owner/admin (H7), o MESMO recorte de Membros e Tipos — daí o
// alias em vez de recopiar a regra. A autoridade real é a policy da API; isto só some da UI o
// que a pessoa não pode fazer.
export const canManageSchedule: (papel: Papel | null | undefined) => boolean = canManageMembers;
