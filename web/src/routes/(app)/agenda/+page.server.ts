import { error, fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import { fetchAgenda, fetchAvailability, createAppointment } from '$lib/server/appointments';
import { parseDateParam, parseHiddenProfs, todayInZone, type ColumnAvailability } from '$lib/agenda';

// Agenda — visão Dia (doc 25, Entrega 1). Carrega agendamentos + expediente do dia da
// clínica ativa. Como em Profissionais/Pacientes, NÃO há recorte de papel no load: todo
// membro lê (a API é que recorta a agenda do `profissional` pela policy A7); só a escrita
// exige papel.

export const load: PageServerLoad = async (event) => {
	const dateParam = event.url.searchParams.get('date');

	// "Pediram uma data" ≠ "mandaram alguma coisa em `?date=`": `?date=ontem` é lixo e cai no
	// hoje da clínica como se não tivesse vindo nada. Sem esta distinção, uma URL inválida
	// mostraria o dia errado.
	const pedida = parseDateParam(dateParam, '');

	// Só quem NÃO pediu data precisa saber que dia é na clínica antes de buscar — e é só o
	// FUSO que falta para isso, porque o relógio é o do nosso próprio servidor. `event.parent()`
	// põe o load do layout e o desta página em fila, então esperá-lo quando a data já veio na
	// URL custaria um round-trip inteiro em toda navegação entre dias, sem usá-lo para nada.
	const date = pedida || todayInZone(new Date().toISOString(), await fusoDaClinica(event));

	const { agenda, availability } = await carregarDia(event, date);

	if (!agenda.data) {
		error(agenda.status || 502, 'Não foi possível carregar a agenda.');
	}

	return {
		appointments: agenda.data.appointments ?? [],
		professionals: agenda.data.professionals ?? [],
		appointmentTypes: agenda.data.appointment_types ?? [],
		patients: agenda.data.patients ?? [],
		availability,
		agora: agenda.data.agora,
		timezone: agenda.data.timezone,
		date,
		// O "hoje" da tela sai do relógio que veio NA RESPOSTA, não do `me`. O `me` é carregado
		// pelo layout, e o SvelteKit não reexecuta load de layout em navegação client-side
		// (`goto`) — um `today` derivado dali congelaria no instante em que a aba abriu, e uma
		// aba atravessando a meia-noite passaria a marcar "Hoje" no dia errado.
		today: todayInZone(agenda.data.agora, agenda.data.timezone),
		hidden: parseHiddenProfs(event.url.searchParams.get('profs'))
	};
};

// O fuso da clínica ativa, do /me que o layout já carregou (ADR-009). Sem ele, UTC: pior dia
// mostrado na janela noturna, nunca tela de erro.
async function fusoDaClinica(event: Parameters<PageServerLoad>[0]): Promise<string> {
	const { me } = await event.parent();
	return me.timezone ?? 'UTC';
}

// Um dia = a agenda + o expediente de cada coluna. Duas requisições, sempre: a da agenda e a
// do expediente de TODAS as colunas de uma vez.
//
// O doc 25 §6 quer a hachura do buraco REAL de cada coluna (não um "almoço" 12–13 igual para
// todos, que é o GAP-05), e `/api/availability` recortava por UM profissional — daí o fan-out
// de uma requisição por coluna que existia aqui, e que o achado (f) do doc 26 mediu em até
// ~480 leituras no banco para um dia com 10 profissionais. Hoje o endpoint aceita a lista
// inteira. A agenda continua vindo primeiro porque é ela que diz QUAIS são as colunas.
async function carregarDia(event: Parameters<PageServerLoad>[0], date: string) {
	const agenda = await fetchAgenda(event, { from: date, to: date });
	if (!agenda.data) return { agenda, availability: [] as ColumnAvailability[] };

	const profs = agenda.data.professionals ?? [];
	if (!profs.length) return { agenda, availability: [] as ColumnAvailability[] };

	const r = await fetchAvailability(event, {
		professional_ids: profs.map((p) => p.id),
		date_from: date,
		date_to: date
	});
	const porProfissional = new Map(r.professionals.map((p) => [p.professional_id, p.days[0]]));

	// A lista sai das COLUNAS, não da resposta: profissional sem expediente devolvido é tratado
	// como FECHADO (hachura inteira) — e não como "expediente desconhecido", que desenharia uma
	// coluna aberta mentindo.
	const availability = profs.map(
		(p): ColumnAvailability => ({
			professional_id: p.id,
			...(porProfissional.get(p.id) ?? { date, periods: [] })
		})
	);

	return { agenda, availability };
}

export const actions: Actions = {
	// Criar agendamento (doc 25 §5). O `starts_at` chega do cliente já em UTC — a conversão
	// "relógio da clínica → instante" é `toUtcIso` ($lib/agenda), testada com um fuso que
	// tem DST. O servidor valida expediente e conflito de qualquer forma; aqui só barramos
	// o que nem faz sentido mandar.
	criar: async (event) => {
		const form = await event.request.formData();

		const starts_at = String(form.get('starts_at') ?? '');
		const professional_id = String(form.get('professional_id') ?? '');
		const appointment_type_id = String(form.get('appointment_type_id') ?? '');

		if (!Number.isFinite(Date.parse(starts_at))) {
			return fail(400, { action: 'criar', error: 'Escolha uma data e um horário válidos.' });
		}
		if (!professional_id || !appointment_type_id) {
			return fail(400, {
				action: 'criar',
				error: 'Escolha o profissional e o tipo de atendimento.'
			});
		}

		const patient_ids = parseIds(form.get('patient_ids'));
		if (!patient_ids.length) {
			return fail(400, { action: 'criar', error: 'Escolha ao menos um paciente.' });
		}

		const obs = String(form.get('obs') ?? '').trim();
		const duracao = Number(form.get('duration_minutos'));

		const result = await createAppointment(event, {
			starts_at,
			professional_id,
			appointment_type_id,
			patient_ids,
			encaixe: form.get('encaixe') === 'on',
			...(obs ? { obs } : {}),
			...(Number.isFinite(duracao) && duracao > 0 ? { duration_minutos: duracao } : {})
		});

		if (!result.ok) {
			// `code` é o que permite à tela OFERECER uma saída (marcar como Encaixe) em vez
			// de só mostrar o erro — ver doc 25 §5 e A-D2.
			return fail(result.status || 400, {
				action: 'criar',
				error: result.error,
				code: result.code,
				details: result.details
			});
		}

		return { ok: true, action: 'criar' };
	}
};

// Os ids vêm como JSON num campo hidden (o form é montado pelo modal). Qualquer coisa fora
// da forma esperada vira lista vazia — e a validação acima devolve a mensagem certa.
function parseIds(raw: FormDataEntryValue | null): string[] {
	try {
		const parsed = JSON.parse(String(raw ?? '[]'));
		if (!Array.isArray(parsed)) return [];
		return parsed.filter((v): v is string => typeof v === 'string' && v.length > 0);
	} catch {
		return [];
	}
}
