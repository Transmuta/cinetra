import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { fetchProfessionals } from '$lib/server/professionals';

// Carrega o diretório da clínica ativa (BFF → /api/professionals): ativos E inativos (o filtro
// da sidebar decide), com o expediente da clínica junto (a coluna "Atendimento" resolve os dias
// herdados). Como em Tipos/Horário, NÃO há recorte de papel no load — todo membro lê; só a
// escrita exige owner/admin (policies da API). Arquivar/reativar mora na ficha (protótipo :2945),
// não na lista — por isso esta rota não tem actions.
export const load: PageServerLoad = async (event) => {
	const result = await fetchProfessionals(event);

	if (!result.data) {
		error(result.status || 502, 'Não foi possível carregar os profissionais.');
	}

	return {
		professionals: result.data.professionals,
		clinicHours: result.data.clinic_hours
	};
};
