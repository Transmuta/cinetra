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

	// Palpite inicial do "hoje" enquanto não sabemos o fuso da clínica (ele vem NA resposta).
	// É o relógio do BFF — nosso servidor, não o do browser.
	const palpite = new Date().toISOString().slice(0, 10);
	// "Pediram uma data" ≠ "mandaram alguma coisa em `?date=`": `?date=ontem` é lixo e cai no
	// hoje da clínica como se não tivesse vindo nada. Sem esta distinção, uma URL inválida
	// congelaria a agenda no palpite em UTC e mostraria o dia errado na janela da noite.
	const explicit = parseDateParam(dateParam, '') !== '';
	let date = explicit ? parseDateParam(dateParam, palpite) : palpite;

	let { agenda, availability } = await carregarDia(event, date);

	if (!agenda.data) {
		error(agenda.status || 502, 'Não foi possível carregar a agenda.');
	}

	const today = todayInZone(agenda.data.agora, agenda.data.timezone);

	// Correção de fronteira: às 22h de São Paulo o UTC já virou o dia seguinte. Sem `?date=`
	// na URL, o que a recepção espera ver é o dia da CLÍNICA — então, se o palpite errou,
	// refaz a busca. Só acontece na janela noturna, e só quando a data não foi pedida.
	if (!explicit && today !== date) {
		date = today;
		({ agenda, availability } = await carregarDia(event, date));
		if (!agenda.data) error(agenda.status || 502, 'Não foi possível carregar a agenda.');
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
		today,
		hidden: parseHiddenProfs(event.url.searchParams.get('profs'))
	};
};

// Um dia = a agenda + o expediente de cada coluna.
//
// `GET /api/availability` recorta por UM profissional, e o doc 25 §6 quer a hachura do
// buraco REAL de cada coluna (não um "almoço" 12–13 igual para todos, que é o GAP-05). Então
// é uma chamada por profissional — disparadas em `Promise.all`, não em fila. Só dá para saber
// QUAIS profissionais depois da resposta da agenda, daí a agenda vir primeiro.
async function carregarDia(event: Parameters<PageServerLoad>[0], date: string) {
	const agenda = await fetchAgenda(event, { from: date, to: date });
	if (!agenda.data) return { agenda, availability: [] as ColumnAvailability[] };

	const profs = agenda.data.professionals ?? [];
	const availability = await Promise.all(
		profs.map(async (p): Promise<ColumnAvailability> => {
			const r = await fetchAvailability(event, {
				professional_id: p.id,
				date_from: date,
				date_to: date
			});
			// Sem resposta para o dia, a coluna é tratada como FECHADA (hachura inteira) — e
			// não como "expediente desconhecido", que desenharia uma coluna aberta mentindo.
			return { professional_id: p.id, ...(r.days[0] ?? { date, periods: [] }) };
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
