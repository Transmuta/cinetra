import { error } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';
import { fetchAudit } from '$lib/server/audit';
import { fetchMembers } from '$lib/server/members';
import {
	parseResource,
	resourceParam,
	parsePage,
	parseAction,
	parsePeriod,
	periodRange
} from '$lib/audit';
import { todayInZone } from '$lib/agenda';

// Tamanho da página do feed. Fica aqui (e não no componente) porque é o load quem traduz
// `?page=` em `offset` para a API — a trilha é a tabela que mais cresce, então a tela é
// paginada por construção (doc 25 §11.4).
const PAGE_SIZE = 50;

// Carrega UMA PÁGINA da trilha da clínica ativa (BFF → /api/audit). É **owner·admin**: a API
// responde 403 para os demais papéis, e aqui isso vira uma página de erro (não uma lista vazia,
// que leria como "sem atividade"). O fuso vem do layout (`me`), então o load não o repete.
export const load: PageServerLoad = async (event) => {
	const params = event.url.searchParams;
	const resource = parseResource(params.get('resource'));
	const action = parseAction(params.get('acao'), resource);
	const period = parsePeriod(params.get('periodo'));
	const autor = params.get('autor') || null;
	const recordId = params.get('record_id') ?? undefined;
	const current = parsePage(params.get('page'));

	// O fuso da clínica ativa (ADR-009) — a janela do período é DIA LOCAL, e "hoje" no fuso do
	// processo não é "hoje" na clínica. O instante é do relógio do servidor; o browser nunca
	// decide que dia é hoje (a mesma regra do `agora` dos relatórios).
	const { me } = await event.parent();
	const timezone = me?.timezone ?? 'America/Sao_Paulo';
	const hoje = todayInZone(new Date().toISOString(), timezone);
	const range = periodRange(period, hoje);

	// A equipe alimenta o filtro "por autor" — e é uma leitura independente da trilha, então as
	// duas saem juntas. Se a equipe falhar, o feed ainda abre: perde-se o filtro, não a tela.
	const membersPromise = fetchMembers(event).catch(() => ({ status: 0, data: null }));

	const res = await fetchAudit(event, {
		// `resource` na URL é o GRUPO ("agenda", "cadastros"); a API recebe os tipos dele
		// separados por vírgula. Sem grupo, o feed é da clínica inteira — o default do doc 63.
		resource: resourceParam(resource),
		action: action ?? undefined,
		user_id: autor ?? undefined,
		record_id: recordId,
		from: range?.from,
		to: range?.to,
		limit: PAGE_SIZE,
		offset: (current - 1) * PAGE_SIZE
	});

	if (res.status === 403) {
		error(403, 'A auditoria é restrita ao dono e aos administradores da clínica.');
	}

	if (!res.data) {
		error(res.status || 502, 'Não foi possível carregar a auditoria.');
	}

	// `user_id` (o autor da versão), não `id` (o do vínculo). Ordenado por nome porque a sidebar
	// o lista como está.
	const autores = ((await membersPromise).data?.members ?? [])
		.filter((m) => m.user_id)
		.map((m) => ({ id: m.user_id as string, nome: m.nome }))
		.sort((a, b) => a.nome.localeCompare(b.nome, 'pt-BR'));

	return {
		entries: res.data.entries,
		pageInfo: res.data.page,
		resource,
		action,
		period,
		autor,
		autores,
		hoje,
		recordId: recordId ?? null,
		current
	};
};
