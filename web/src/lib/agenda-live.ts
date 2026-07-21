// O patch de tempo real sobre o que o `load` trouxe (Entrega 3, contrato 09 §7.2).
//
// Funções puras, fora do `.svelte`, por dois motivos: página `.svelte` fica fora do gate de
// cobertura, e a regra que mora aqui — "evento mais velho não desfaz estado mais novo" — é
// exatamente do tipo que só falha em corrida e nunca em inspeção visual.
//
// O evento é OTIMIZAÇÃO sobre um estado que o REST sempre pode reconstituir (09 §7.5): se um
// patch não for aplicável, o caminho é recarregar, nunca inventar.
import type { Appointment, AgendaPatient } from './agenda';
import { zonedParts } from './agenda';

/**
 * Aplica um bloco a uma lista de **um dia** (Dia/Lista), removendo-o quando ele deixou de
 * pertencer àquele dia.
 *
 * É o que fecha o "bloco fantasma" da remarcação entre dias (Entrega 4, risco do doc 25 §9): o
 * tópico de origem recebe o mesmo evento, agora com o `starts_at` no dia de destino. Sem esta
 * checagem, `applyAppointment` re-inseriria o bloco na lista do dia de origem, num horário
 * fora da grade. Com ela, o dia de origem o **remove** (ele foi embora) e o de destino o adiciona.
 */
export function applyToDay(
	list: Appointment[],
	incoming: Appointment,
	date: string,
	timezone: string
): Appointment[] {
	if (zonedParts(incoming.starts_at, timezone).date === date) {
		return applyAppointment(list, incoming);
	}
	// Saiu deste dia: some daqui (se estava). Não é "descartar o evento" — é aplicá-lo.
	return list.filter((a) => a.id !== incoming.id);
}

/**
 * Aplica um bloco recebido por evento sobre a lista atual.
 *
 * `version` é o desempate: o Ash incrementa a cada escrita, então um evento que chega atrasado
 * (rede, reconexão, os dois broadcasts da mesma escrita) traz versão menor e é descartado.
 * Versão IGUAL passa: é o caso do merge de turma, que acrescenta participante sem escrever no
 * `Appointment`.
 */
export function applyAppointment(list: Appointment[], incoming: Appointment): Appointment[] {
	const i = list.findIndex((a) => a.id === incoming.id);

	if (i === -1) return ordenar([...list, incoming]);
	if (list[i].version > incoming.version) return list;

	const copy = list.slice();
	copy[i] = incoming;
	return ordenar(copy);
}

/**
 * Funde o sidecar de pacientes do evento no que a página já tem.
 *
 * Sem isto, um bloco criado para alguém fora da janela carregada apareceria com o nome
 * genérico "Paciente" até o próximo refresh — o mapa de nomes é montado do sidecar.
 */
export function mergePatients(list: AgendaPatient[], incoming: AgendaPatient[]): AgendaPatient[] {
	if (!incoming.length) return list;

	const porId = new Map(list.map((p) => [p.id, p]));
	for (const p of incoming) porId.set(p.id, p);

	return [...porId.values()];
}

// A API devolve a janela ordenada por `starts_at`; um bloco chegando por evento não pode
// deixar a lista numa ordem que o REST nunca produziria.
function ordenar(list: Appointment[]): Appointment[] {
	return list.sort((a, b) => a.starts_at.localeCompare(b.starts_at));
}
