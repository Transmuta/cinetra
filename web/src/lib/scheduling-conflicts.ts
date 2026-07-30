/**
 * **A3 / D12** — a leitura do 409 `future_conflicts` no cliente.
 *
 * A API recusa uma mudança de horário que deixaria agendamentos futuros fora do expediente e
 * devolve, no `meta` do 409, **quais**. Este módulo é o parse desse payload e as frases que a
 * tela mostra. Puro: quem abre o modal é a página.
 */

export type ConflictReason = 'sem_atendimento' | 'fora_do_expediente';

export interface FutureConflict {
	appointment_id: string;
	/** ISO local da clínica ("2026-07-20"). */
	date: string;
	/** "HH:MM" local. */
	hora: string;
	reason: ConflictReason;
	periods_depois: [string, string][];
	professional: { id: string; nome: string | null };
	patients: string[];
}

export interface FutureConflicts {
	/** Os primeiros afetados, detalhados (o servidor manda no máximo 10). */
	conflicts: FutureConflict[];
	/** O número **real** de agendamentos afetados — sem teto. */
	total: number;
}

/**
 * Lê o `meta` do 409. Devolve `null` quando o erro **não** é de conflito futuro — é o que a tela
 * usa para decidir entre abrir o modal e mostrar um toast.
 *
 * Defensivo por contrato: o `meta` chega de JSON não-tipado, e uma linha meio-formada aqui viraria
 * uma linha vazia numa lista que existe justamente para a pessoa decidir o que remarcar.
 */
export function parseFutureConflicts(
	code: unknown,
	meta: unknown
): FutureConflicts | null {
	if (code !== 'future_conflicts') return null;
	if (typeof meta !== 'object' || meta === null) return null;

	const bruto = (meta as { conflicts?: unknown }).conflicts;
	if (!Array.isArray(bruto)) return null;

	const conflicts = bruto.filter(isConflict);
	if (!conflicts.length) return null;

	const total = (meta as { total?: unknown }).total;

	return { conflicts, total: typeof total === 'number' ? total : conflicts.length };
}

function isConflict(v: unknown): v is FutureConflict {
	if (typeof v !== 'object' || v === null) return false;
	const c = v as Record<string, unknown>;

	return (
		typeof c.appointment_id === 'string' &&
		typeof c.date === 'string' &&
		typeof c.hora === 'string' &&
		(c.reason === 'sem_atendimento' || c.reason === 'fora_do_expediente')
	);
}

/** "20/07" — a data curta da linha (a lista já é do futuro próximo; o ano seria ruído). */
export function diaCurto(iso: string): string {
	const [, mes, dia] = iso.split('-');
	return mes && dia ? `${dia}/${mes}` : iso;
}

/** A frase do motivo, na forma que a pessoa lê para decidir o que fazer. */
export function motivoLabel(conflito: FutureConflict): string {
	if (conflito.reason === 'sem_atendimento') return 'Sem atendimento nesse dia';

	const janelas = conflito.periods_depois.map(([ini, fim]) => `${ini}–${fim}`).join(', ');
	return janelas ? `Fora do novo expediente (${janelas})` : 'Fora do novo expediente';
}

/** O cabeçalho do modal: quantos ficariam fora, pelo número REAL. */
export function resumoConflitos({ total }: FutureConflicts): string {
	return total === 1
		? '1 agendamento futuro ficaria fora do expediente'
		: `${total} agendamentos futuros ficariam fora do expediente`;
}

/**
 * A linha abaixo da lista quando o servidor detalhou só os primeiros. Vazia quando a lista já
 * mostra tudo — não se avisa sobre um resto que não existe.
 */
export function restoNaoListado({ conflicts, total }: FutureConflicts): string {
	const resto = total - conflicts.length;

	if (resto <= 0) return '';

	return resto === 1
		? 'e mais 1 agendamento não listado aqui'
		: `e mais ${resto} agendamentos não listados aqui`;
}
