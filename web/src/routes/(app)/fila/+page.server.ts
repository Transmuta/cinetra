import { error, fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import {
	fetchWaitlist,
	enqueueEntry,
	updateEntry,
	dequeueEntry,
	offerSlot,
	convertEntry,
	type UpdateInput
} from '$lib/server/waitlist';
import { fetchAppointmentTypes } from '$lib/server/appointment-types';
import type { MutationResult } from '$lib/server/mutate';
import { parsePriorityFilter, type Priority, type Rule, type TimeWindow } from '$lib/waitlist';

// Fila de espera (doc 25, Entrega 5). Molde de Pacientes no load (todo membro lê; o `?prio` é o
// segmento da sidebar) e de Agenda nas actions (uma por operação, mesmo formato de retorno com
// `code` propagado). O `?prio` é filtrado no CLIENTE (a fila é bounded — não paginada — e o GET
// devolve tudo, como o `filaVagas`/`renderFila` do protótipo); aqui ele só viaja para a tela e a
// sidebar. Como em toda a agenda, NÃO há recorte de papel no load — a API é que recorta.
export const load: PageServerLoad = async (event) => {
	// Etiqueta de invalidação do tempo real (D-E5.3): o sinal `waitlist_changed` do canal
	// reexecuta SÓ este load (`invalidate('fila:dados')`), sem arrastar o do layout.
	event.depends('fila:dados');

	// O fuso vem do /me do layout (ADR-009): a conversão vaga-local → instante UTC da conversão
	// acontece no cliente (`toUtcIso`), e sem o fuso ela erraria por horas — invisível em UTC.
	const [{ me }, wl, types] = await Promise.all([
		event.parent(),
		fetchWaitlist(event),
		fetchAppointmentTypes(event)
	]);

	if (!wl.data) {
		error(wl.status || 502, 'Não foi possível carregar a fila de espera.');
	}

	return {
		waitlist: wl.data.waitlist,
		professionals: wl.data.professionals,
		// Ativos E arquivados (a API manda os dois); o seletor da conversão filtra os ativos.
		appointmentTypes: types.data?.appointment_types ?? [],
		timezone: me.timezone ?? 'UTC',
		prio: parsePriorityFilter(event.url.searchParams.get('prio'))
	};
};

export const actions: Actions = {
	// Adicionar à fila (upsert por paciente). `professional_ids` e `rules` chegam como JSON em
	// campos hidden (o modal os monta). Só barramos aqui o que nem faz sentido mandar; a forma
	// das regras (`RuleShape`) e a permissão são do servidor.
	enqueue: async (event) => {
		const form = await event.request.formData();
		const patient_id = String(form.get('patient_id') ?? '');
		if (!patient_id) return fail(400, { action: 'enqueue', error: 'Escolha um paciente.' });

		const obs = String(form.get('obs') ?? '').trim();

		return finish(
			'enqueue',
			await enqueueEntry(event, {
				patient_id,
				prio: parsePrio(form.get('prio')),
				janela: parseJanela(form.get('janela')),
				professional_ids: parseIds(form.get('professional_ids')),
				rules: parseRules(form.get('rules')),
				...(obs ? { obs } : {})
			})
		);
	},

	// Editar um item. É a mesma tela do adicionar, com `id`; manda o conjunto inteiro de campos
	// (o modal mostra todos e submete todos) — inclusive `obs` vazio, que aqui LIMPA a observação.
	atualizar: async (event) => {
		const s = await submission(event, 'atualizar');
		if (!('id' in s)) return s;
		const { form, id } = s;

		const input: UpdateInput = {
			prio: parsePrio(form.get('prio')),
			janela: parseJanela(form.get('janela')),
			professional_ids: parseIds(form.get('professional_ids')),
			rules: parseRules(form.get('rules')),
			obs: String(form.get('obs') ?? '').trim()
		};

		return finish('atualizar', await updateEntry(event, id, input));
	},

	// Sair da fila (a lixeira). Destroy de verdade — regras e holds vão junto pelo cascade.
	remover: async (event) => {
		const s = await submission(event, 'remover');
		if (!('id' in s)) return s;
		return finish('remover', await dequeueEntry(event, s.id));
	},

	// Segurar a vaga (offer). O 409 `slot_held` sobe com `code` — a tela mostra quem está
	// oferecendo, sem saída de encaixe (é reserva de outra pessoa, não conflito de grade).
	oferecer: async (event) => {
		const s = await submission(event, 'oferecer');
		if (!('id' in s)) return s;
		const { form, id } = s;

		const starts_at = String(form.get('starts_at') ?? '');
		const professional_id = String(form.get('professional_id') ?? '');
		if (!Number.isFinite(Date.parse(starts_at)) || !professional_id) {
			return fail(400, { action: 'oferecer', error: 'Escolha um horário e um profissional.' });
		}

		const duracao = Number(form.get('duration_minutos'));

		return finish(
			'oferecer',
			await offerSlot(event, id, {
				professional_id,
				starts_at,
				...(Number.isFinite(duracao) && duracao > 0 ? { duration_minutos: duracao } : {})
			})
		);
	},

	// Converter a vaga em agendamento (e sair da fila). `starts_at` já em UTC (o cliente converte
	// pelo fuso da clínica). Propaga `schedule_conflict` (422) para a tela oferecer o Encaixe.
	converter: async (event) => {
		const s = await submission(event, 'converter');
		if (!('id' in s)) return s;
		const { form, id } = s;

		const starts_at = String(form.get('starts_at') ?? '');
		if (!Number.isFinite(Date.parse(starts_at))) {
			return fail(400, { action: 'converter', error: 'Escolha uma data e um horário válidos.' });
		}

		const professional_id = String(form.get('professional_id') ?? '');
		const appointment_type_id = String(form.get('appointment_type_id') ?? '');
		if (!professional_id || !appointment_type_id) {
			return fail(400, {
				action: 'converter',
				error: 'Escolha o profissional e o tipo de atendimento.'
			});
		}

		const obs = String(form.get('obs') ?? '').trim();
		const duracao = Number(form.get('duration_minutos'));

		return finish(
			'converter',
			await convertEntry(event, id, {
				starts_at,
				professional_id,
				appointment_type_id,
				encaixe: form.get('encaixe') === 'on' || form.get('encaixe') === 'true',
				...(obs ? { obs } : {}),
				...(Number.isFinite(duracao) && duracao > 0 ? { duration_minutos: duracao } : {})
			})
		);
	}
};

// Lê o corpo e exige o `id` do item — o preâmbulo das actions com id próprio (molde da agenda).
async function submission(event: Parameters<Actions[string]>[0], action: string) {
	const form = await event.request.formData();
	const id = String(form.get('id') ?? '');
	if (!id) return fail(400, { action, error: 'Item da fila não informado.' });
	return { form, id };
}

// Traduz o resultado do BFF no retorno da action. O `code` é o que deixa a tela distinguir o
// `slot_held`/`schedule_conflict` (mostra quem segura / oferece encaixe) do erro genérico.
function finish(action: string, result: MutationResult) {
	if (result.ok) return { ok: true, action };
	return fail(result.status || 400, {
		action,
		error: result.error,
		code: result.code,
		details: result.details
	});
}

// Prioridade/janela do cliente não são de confiança: casam contra os valores conhecidos e caem
// no default (o `<select>` só oferece válidos, mas o servidor não terceriza a validação ao form).
const PRIOS: readonly Priority[] = ['urgente', 'alta', 'normal', 'baixa'];
function parsePrio(raw: FormDataEntryValue | null): Priority {
	const v = String(raw ?? '');
	return PRIOS.find((p) => p === v) ?? 'normal';
}

const JANELAS: readonly TimeWindow[] = ['manha', 'tarde', 'qualquer'];
function parseJanela(raw: FormDataEntryValue | null): TimeWindow {
	const v = String(raw ?? '');
	return JANELAS.find((j) => j === v) ?? 'qualquer';
}

// professional_ids vem como JSON num hidden (o modal o monta). Qualquer coisa fora da forma
// esperada vira lista vazia — o mesmo tratamento de `parseIds` da agenda.
function parseIds(raw: FormDataEntryValue | null): string[] {
	try {
		const parsed = JSON.parse(String(raw ?? '[]'));
		if (!Array.isArray(parsed)) return [];
		return parsed.filter((v): v is string => typeof v === 'string' && v.length > 0);
	} catch {
		return [];
	}
}

// `rules` também é JSON num hidden. Normaliza defensivamente (a `RuleShape` do servidor é a
// autoridade da forma; aqui só evitamos mandar lixo estrutural que estouraria antes dela).
function parseRules(raw: FormDataEntryValue | null): Rule[] {
	try {
		const parsed = JSON.parse(String(raw ?? '[]'));
		if (!Array.isArray(parsed)) return [];
		return parsed
			.filter((r): r is Record<string, unknown> => typeof r === 'object' && r !== null)
			.map((r): Rule => ({
				...(typeof r.id === 'string' && r.id ? { id: r.id } : {}),
				tipo: r.tipo === 'data' ? 'data' : 'semana',
				dows: Array.isArray(r.dows)
					? r.dows.filter((d): d is number => Number.isInteger(d) && d >= 0 && d <= 6)
					: [],
				data: typeof r.data === 'string' && r.data ? r.data : null,
				periodos: Array.isArray(r.periodos)
					? r.periodos.filter(
							(p): p is [string, string] =>
								Array.isArray(p) && p.length === 2 && typeof p[0] === 'string' && typeof p[1] === 'string'
						)
					: []
			}));
	} catch {
		return [];
	}
}
