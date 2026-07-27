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
	conflicts: FutureConflict[];
	/** O servidor bateu no teto de leitura — há mais do que a lista mostra. */
	truncado: boolean;
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

	return { conflicts, truncado: (meta as { truncado?: unknown }).truncado === true };
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

/** O cabeçalho do modal: quantos, e a ressalva quando a lista foi cortada pelo teto. */
export function resumoConflitos({ conflicts, truncado }: FutureConflicts): string {
	const n = conflicts.length;
	const base =
		n === 1
			? '1 agendamento futuro ficaria fora do expediente'
			: `${n} agendamentos futuros ficariam fora do expediente`;

	return truncado ? `${base} (e possivelmente mais)` : base;
}
