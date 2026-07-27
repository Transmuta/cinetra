import { json } from '@sveltejs/kit';
import type { RequestEvent } from '@sveltejs/kit';
import { fetchPatients } from './patients';

/**
 * A busca do `PatientPicker` — o autocomplete de paciente dos modais da agenda e da fila.
 *
 * Endpoint próprio em vez de carregar o cadastro no load da tela: paciente é a entidade que cresce
 * sem limite, e a lista de Pacientes já ensinou que carrega-tudo vira dívida.
 *
 * Nasceu duas vezes, byte a byte (`/agenda/pacientes` e `/fila/pacientes`) — é o **D3** do doc 29
 * §5, cobrado na Frente 13. As duas rotas continuam existindo (o picker de cada tela chama a sua),
 * mas a regra é uma só: mexer no teto, no mínimo de caracteres ou na projeção passou a ser mexer
 * num lugar.
 */

/** Mesmo teto do protótipo (:1949): 10 resultados + o total, para o aviso "refine a busca". */
export const LIMITE = 10;

/** Mínimo de caracteres para consultar. Vale no SERVIDOR, não só no debounce do cliente. */
export const MINIMO_CARACTERES = 2;

const VAZIO = { patients: [], total: 0 };

export async function searchPatients(event: RequestEvent) {
	const q = event.url.searchParams.get('q')?.trim() ?? '';

	// A regra dos 2 caracteres também vale no SERVIDOR: confiar no debounce do cliente deixaria a
	// porta aberta para um "a" varrer o cadastro a cada tecla.
	if (q.length < MINIMO_CARACTERES) return json(VAZIO);

	const r = await fetchPatients(event, { q, filter: 'ativos', limit: LIMITE });
	if (!r.data) return json(VAZIO);

	// Projeção mínima: o picker desenha avatar, nome e telefone. CPF e o resto da ficha são dado
	// sensível e não têm por que trafegar para um autocomplete.
	return json({
		patients: r.data.patients.map((p) => ({
			id: p.id,
			nome: p.nome,
			tel: p.tel,
			cor_indice: p.cor_indice
		})),
		total: r.data.page?.total ?? r.data.patients.length
	});
}
