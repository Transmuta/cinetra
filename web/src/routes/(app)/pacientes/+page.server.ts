import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { fetchPatients } from '$lib/server/patients';
import { fetchProfessionals } from '$lib/server/professionals';
import { parseFilter, parsePage } from '$lib/patients';

// Tamanho da página da lista. Fica aqui (e não no componente) porque é o load quem traduz
// `?page=` em `offset` para a API.
const PAGE_SIZE = 50;

// Carrega UMA PÁGINA do cadastro da clínica ativa (BFF → /api/patients), já buscada e filtrada
// no servidor — paciente é a entidade que cresce sem limite, então aqui não cabe carrega-tudo.
// Junto vem o diretório de profissionais, só para resolver os nomes da coluna "Preferência".
// Como em Profissionais/Tipos, NÃO há recorte de papel no load — todo membro lê; só a escrita
// exige owner/admin (policies da API).
export const load: PageServerLoad = async (event) => {
	const q = event.url.searchParams.get('q')?.trim() ?? '';
	const filter = parseFilter(event.url.searchParams.get('filter'));
	const current = parsePage(event.url.searchParams.get('page'));

	const [pat, prof] = await Promise.all([
		fetchPatients(event, { q, filter, limit: PAGE_SIZE, offset: (current - 1) * PAGE_SIZE }),
		fetchProfessionals(event)
	]);

	if (!pat.data) {
		error(pat.status || 502, 'Não foi possível carregar os pacientes.');
	}

	return {
		patients: pat.data.patients,
		pageInfo: pat.data.page,
		counts: pat.data.counts,
		professionals: prof.data?.professionals ?? [],
		q,
		filter,
		current
	};
};
