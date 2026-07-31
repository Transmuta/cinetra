// Data e hora **no fuso da clínica**, para leitura humana.
//
// Existe porque a mesma conversão "instante ISO → dia e hora" estava escrita cinco vezes dentro
// de `.svelte` (doc 93 §B-1) — duas byte-idênticas, duas variantes do mesmo formato — e junto com
// elas três listas de dia da semana com três nomes, enquanto `DOW_LABELS` já existia. Lógica pura
// morando em componente fica fora do gate de cobertura, então nenhuma das cinco era testada.
//
// O fuso é sempre PARÂMETRO, nunca o do browser: quem lê a agenda de uma clínica em outro estado
// tem de ver o horário da clínica, não o seu.

import { m2t, zonedParts } from './agenda';

/** Rótulos indexados por `getUTCDay()` — domingo é 0. */
export const DOW_LABELS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];

/**
 * Dia da semana de uma data de calendário ("AAAA-MM-DD").
 *
 * O meio-dia UTC não é enfeite: `new Date('2026-07-30')` é meia-noite UTC, e em qualquer fuso a
 * oeste isso ainda é o dia 29 — o rótulo sairia um dia atrasado. Como a entrada já é a data
 * **local da clínica** (o `zonedParts` já converteu), o que se quer aqui é só o dia da semana
 * daquele número de calendário, sem fuso nenhum atravessando de novo.
 */
export function diaSemana(date: string): string {
	return DOW_LABELS[new Date(`${date}T12:00:00Z`).getUTCDay()];
}

/** "AAAA-MM-DD" → "DD/MM". */
export function diaMes(date: string): string {
	const [, mes, dia] = date.split('-');
	return `${dia}/${mes}`;
}

/**
 * "30/07/2026 · 08:00" — a ficha do paciente (histórico e próximas).
 *
 * Sem dia da semana de propósito: ali a lista é longa e a data cheia é o que a recepção confere
 * contra o papel.
 */
export function quandoSemDia(iso: string, timezone: string): string {
	const { date, minutes } = zonedParts(iso, timezone);
	const [ano, mes, dia] = date.split('-');
	return `${dia}/${mes}/${ano} · ${m2t(minutes)}`;
}

/** "Qui 30/07/26 · 08:00" — o cartão do pacote, onde o ano importa e o espaço não sobra. */
export function quandoComAno(iso: string, timezone: string): string {
	const { date, minutes } = zonedParts(iso, timezone);
	const [ano, mes, dia] = date.split('-');
	return `${diaSemana(date)} ${dia}/${mes}/${ano.slice(2)} · ${m2t(minutes)}`;
}

/** "Qui 30/07 · 08:00" — a trilha do pacote, cujas linhas dividem o mesmo ano. */
export function quandoCurto(iso: string, timezone: string): string {
	const { date, minutes } = zonedParts(iso, timezone);
	return `${diaSemana(date)} ${diaMes(date)} · ${m2t(minutes)}`;
}
