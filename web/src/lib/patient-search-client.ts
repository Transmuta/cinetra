// A busca de paciente do `PatientPicker`, do lado do BROWSER.
//
// Duas telas montam o mesmo picker — a agenda (novo agendamento) e a fila (adicionar à fila) — e
// cada uma tinha a sua cópia da função, idêntica a menos da URL (doc 94 §D-4).
//
// A degradação para lista vazia é contrato, não descuido: o picker que não acha nada mostra o
// vazio ("nenhum paciente"), e é isso que se quer quando a rede falha no meio de uma digitação.
// Estourar aqui derrubaria o modal inteiro por causa de uma tecla.

import type { SearchResult } from './agenda';

const VAZIO: SearchResult = { patients: [], total: 0 };

/**
 * @param base rota do endpoint da tela (`/agenda/pacientes` ou `/fila/pacientes`) — cada uma tem
 *             a sua porque o recorte de papel difere, e a URL é a única diferença entre as duas.
 */
export async function buscarPacientes(base: string, q: string): Promise<SearchResult> {
	try {
		const res = await fetch(`${base}?q=${encodeURIComponent(q)}`);
		if (!res.ok) return VAZIO;
		return (await res.json()) as SearchResult;
	} catch {
		return VAZIO;
	}
}
