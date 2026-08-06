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

// ---- a quarta forma: a que fala com o PACIENTE ----
//
// As três acima falam com a recepção, que confere data contra papel e lê "30/07/2026" o dia
// inteiro. A de baixo é para quem abriu um link no ônibus e está decidindo se sai de casa: ali o
// dia da semana é a informação, e "amanhã" vem antes dele.

const DOW_EXTENSO = [
	'domingo',
	'segunda-feira',
	'terça-feira',
	'quarta-feira',
	'quinta-feira',
	'sexta-feira',
	'sábado'
];

const MESES = [
	'janeiro',
	'fevereiro',
	'março',
	'abril',
	'maio',
	'junho',
	'julho',
	'agosto',
	'setembro',
	'outubro',
	'novembro',
	'dezembro'
];

export interface QuandoPaciente {
	/** "quarta-feira, 5 de agosto" — com o ano só quando ele não é o corrente. */
	extenso: string;
	/** "08:30", no fuso da clínica. */
	hora: string;
	/** O atalho que dispensa ler a data. Além de amanhã não há: "em 3 dias" não ajuda ninguém. */
	proximidade: 'hoje' | 'amanhã' | null;
	/** A sessão já começou. O link vale 30 dias — a sessão, não. */
	passou: boolean;
}

/**
 * A sessão como o paciente precisa lê-la.
 *
 * `agora` é **parâmetro**, e não `new Date()`: quem chama é o `load` do BFF, que roda no servidor,
 * e um relógio lido aqui dentro tornaria a função intestável e o SSR divergente da hidratação.
 */
export function quandoParaPaciente(
	iso: string,
	timezone: string,
	agora: string
): QuandoPaciente {
	const { date, minutes } = zonedParts(iso, timezone);
	const hoje = zonedParts(agora, timezone).date;
	const [ano, mes, dia] = date.split('-');

	// Meio-dia UTC pela mesma razão da `diaSemana`: a data já está no calendário da clínica, e
	// deixar o fuso atravessar de novo tiraria um dia em qualquer longitude a oeste.
	const meioDia = (d: string) => Date.parse(`${d}T12:00:00Z`);
	const dias = Math.round((meioDia(date) - meioDia(hoje)) / 86_400_000);

	return {
		extenso:
			`${DOW_EXTENSO[new Date(`${date}T12:00:00Z`).getUTCDay()]}, ` +
			`${Number(dia)} de ${MESES[Number(mes) - 1]}` +
			(ano === hoje.slice(0, 4) ? '' : ` de ${ano}`),
		hora: m2t(minutes),
		proximidade: dias === 0 ? 'hoje' : dias === 1 ? 'amanhã' : null,
		passou: Date.parse(iso) < Date.parse(agora)
	};
}
