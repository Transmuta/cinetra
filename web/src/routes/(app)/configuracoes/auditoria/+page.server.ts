import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { fetchAudit } from '$lib/server/audit';
import { parseResource, parsePage } from '$lib/audit';

// Tamanho da página do feed. Fica aqui (e não no componente) porque é o load quem traduz
// `?page=` em `offset` para a API — a trilha é a tabela que mais cresce, então a tela é
// paginada por construção (doc 25 §11.4).
const PAGE_SIZE = 50;

// Carrega UMA PÁGINA da trilha da clínica ativa (BFF → /api/audit). Ao contrário das outras
// telas de Configurações, esta é **owner·admin**: a API responde 403 para os demais papéis, e
// aqui isso vira uma página de erro (não uma lista vazia, que leria como "sem atividade"). O
// fuso e o papel do usuário vêm do layout (`data.me`), então o load não os repete.
export const load: PageServerLoad = async (event) => {
	const resource = parseResource(event.url.searchParams.get('resource'));
	const action = event.url.searchParams.get('action') ?? undefined;
	const recordId = event.url.searchParams.get('record_id') ?? undefined;
	const current = parsePage(event.url.searchParams.get('page'));

	const res = await fetchAudit(event, {
		resource,
		action,
		record_id: recordId,
		limit: PAGE_SIZE,
		offset: (current - 1) * PAGE_SIZE
	});

	if (res.status === 403) {
		error(403, 'A auditoria é restrita ao dono e aos administradores da clínica.');
	}

	if (!res.data) {
		error(res.status || 502, 'Não foi possível carregar a auditoria.');
	}

	return {
		entries: res.data.entries,
		pageInfo: res.data.page,
		resource,
		action: action ?? null,
		recordId: recordId ?? null,
		current
	};
};
