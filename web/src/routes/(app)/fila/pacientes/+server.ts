import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { fetchPatients } from '$lib/server/patients';

// Busca de pacientes do `PatientPicker` do modal "Adicionar à fila" (doc 25, Entrega 5). Gêmeo do
// `/agenda/pacientes`: endpoint próprio em vez de carregar o cadastro no load da fila — paciente é
// a entidade que cresce sem limite, e carrega-tudo já virou dívida na lista de Pacientes.
//
// É um `+server` consumido por `fetch` do cliente — não por `<a>`, então o gotcha do
// `data-sveltekit-reload` não se aplica aqui.

/** Mesmo teto do protótipo (:1949): 10 resultados + o total, para o aviso "refine a busca". */
const LIMITE = 10;

export const GET: RequestHandler = async (event) => {
	const q = event.url.searchParams.get('q')?.trim() ?? '';

	// A regra dos 2 caracteres também vale no SERVIDOR: confiar no debounce do cliente deixaria a
	// porta aberta para um "a" varrer o cadastro a cada tecla.
	if (q.length < 2) return json({ patients: [], total: 0 });

	const r = await fetchPatients(event, { q, filter: 'ativos', limit: LIMITE });
	if (!r.data) return json({ patients: [], total: 0 });

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
};
