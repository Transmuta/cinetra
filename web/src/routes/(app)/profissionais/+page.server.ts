import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { fetchProfessionals } from '$lib/server/professionals';

// Carrega o diretório da clínica ativa (BFF → /api/professionals): ativos E inativos (o filtro
// da sidebar decide), com o expediente da clínica junto (a coluna "Atendimento" resolve os dias
// herdados). A escrita exige owner/admin (policies da API); a leitura, desde 2026-08-04 (doc
// 103), exige não ser o próprio profissional — a tela deixou de ser dele. Arquivar/reativar mora
// na ficha (protótipo :2945), não na lista — por isso esta rota não tem actions.
export const load: PageServerLoad = async (event) => {
	const result = await fetchProfessionals(event);

	// O 403 tem mensagem própria: "não foi possível carregar" leria como falha de rede numa
	// tela que, para este papel, simplesmente não existe — e mandaria a pessoa tentar de novo.
	if (result.status === 403) {
		error(403, 'Esta tela não está disponível para o seu perfil.');
	}

	if (!result.data) {
		error(result.status || 502, 'Não foi possível carregar os profissionais.');
	}

	return {
		professionals: result.data.professionals,
		clinicHours: result.data.clinic_hours
	};
};
