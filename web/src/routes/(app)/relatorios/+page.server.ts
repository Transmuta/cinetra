import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { fetchReports } from '$lib/server/reports';
import { parsePeriod, periodWindow } from '$lib/reports';
import { todayInZone } from '$lib/agenda';

// Carrega o agregado do período (BFF → /api/reports/summary). Como Profissionais/Pacientes, NÃO
// há recorte de papel no load: todo membro lê, e é a API que recorta os números do `profissional`
// à própria agenda (doc 33 §3). O filtro de profissional (`?prof=`) só é ATENDIDO para os papéis
// que veem a clínica inteira — para o `profissional` a API o ignora e devolve os próprios.
export const load: PageServerLoad = async (event) => {
	const period = parsePeriod(event.url.searchParams.get('period'));
	const prof = event.url.searchParams.get('prof') ?? '';

	// O "hoje" da clínica antes do fetch: preciso das datas da janela para pedir. Vem do fuso do
	// /me que o layout já carregou (ADR-009), com o relógio do próprio servidor — o mesmo caminho
	// da Agenda. Sem fuso, UTC: pior dia na janela noturna, nunca tela de erro.
	const { me } = await event.parent();
	const today = todayInZone(new Date().toISOString(), me.timezone ?? 'UTC');
	const range = periodWindow(period, today);

	const res = await fetchReports(event, {
		date_from: range.from,
		date_to: range.to,
		// 'todos' e vazio não filtram; um uuid recorta (para quem pode).
		professional_id: prof && prof !== 'todos' ? prof : undefined
	});

	if (!res.data) {
		error(res.status || 502, 'Não foi possível carregar os relatórios.');
	}

	return {
		report: res.data,
		period,
		prof: prof || 'todos',
		// A sidebar de filtros (Sidebar.svelte) lê a lista de profissionais daqui, como a Agenda.
		professionals: res.data.professionals
	};
};
