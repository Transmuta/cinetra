import { error, fail } from '@sveltejs/kit';
import type { Actions, PageServerLoad } from './$types';
import {
	fetchAgenda,
	fetchAvailability,
	fetchCounts,
	createAppointment,
	rescheduleAppointment,
	cancelAppointment,
	reopenAppointment,
	excludeAppointment,
	transitionParticipant
} from '$lib/server/appointments';
import { finish, parseIds, type MutationResult } from '$lib/server/mutate';
import {
	parseDateParam,
	parseHiddenProfs,
	todayInZone,
	PARTICIPANT_KINDS,
	type ColumnAvailability,
	type ParticipantKind
} from '$lib/agenda';
import {
	parseView,
	weekDays,
	monthWindow,
	type AgendaView,
	type DayCount
} from '$lib/agenda-views';
import { fetchPatient } from '$lib/server/patients';
import { sendConfirmation } from '$lib/server/messages';
import { textoDoEnvio } from '$lib/messages';
import { convertEntry } from '$lib/server/waitlist';
import type { AgendaPatient } from '$lib/agenda';

// Agenda (doc 25, Entregas 1 e 2). Quatro visões, duas formas de carregar:
//
//  - **Dia** e **Lista** leem BLOCOS de um dia só. São o mesmo dado em dois renders (B-D1);
//    só o Dia precisa também do expediente, que é a hachura da grade.
//  - **Semana** e **Mês** leem CONTAGENS. Mês não carrega bloco nenhum (doc 25 §10): 31 dias
//    de agendamentos com pacientes e attendances é outra ordem de grandeza de payload para
//    desenhar uma barra por dia.
//
// Como em Profissionais/Pacientes, NÃO há recorte de papel no load: todo membro lê (a API é
// que recorta a agenda do `profissional` pela policy A7); só a escrita exige papel.

export const load: PageServerLoad = async (event) => {
	// Etiqueta de invalidação do tempo real (Entrega 3). O evento do canal é OTIMIZAÇÃO sobre um
	// estado que o REST sempre pode reconstituir (09 §7.5): Semana e Mês recarregam por aqui (a
	// contagem agregada não dá para remendar a partir de um bloco), e é também o caminho de
	// ressincronização depois de uma reconexão. `invalidate` desta chave reexecuta só este load
	// — `invalidateAll` arrastaria junto o do layout.
	event.depends('agenda:dados');

	const view = parseView(event.url.searchParams.get('view'));

	// "Pediram uma data" ≠ "mandaram alguma coisa em `?date=`": `?date=ontem` é lixo e cai no
	// hoje da clínica como se não tivesse vindo nada. Sem esta distinção, uma URL inválida
	// mostraria o dia errado.
	const pedida = parseDateParam(event.url.searchParams.get('date'), '');

	// Só quem NÃO pediu data precisa saber que dia é na clínica antes de buscar — e é só o
	// FUSO que falta para isso, porque o relógio é o do nosso próprio servidor. `event.parent()`
	// põe o load do layout e o desta página em fila, então esperá-lo quando a data já veio na
	// URL custaria um round-trip inteiro em toda navegação entre dias, sem usá-lo para nada.
	const date = pedida || todayInZone(new Date().toISOString(), await fusoDaClinica(event));

	// `?paciente=<id>` — o "Agendar" da ficha (doc 51 §L2). Resolve o paciente aqui para a tela
	// poder abrir o modal já com ele escolhido; sem isso o botão devolveria a recepção à busca de
	// que ela acabou de sair. Só o ID viaja na URL (nome de paciente em URL entra em histórico e
	// log de proxy); o nome vem desta leitura, autenticada e escopada.
	const presetPatient = await carregarPreset(event);

	const comum = {
		view,
		date,
		hidden: parseHiddenProfs(event.url.searchParams.get('profs')),
		presetPatient
	};

	if (view === 'semana' || view === 'mes') {
		return { ...comum, ...(await carregarContagens(event, view, date)) };
	}

	const { agenda, availability } = await carregarDia(event, date, view);

	if (!agenda.data) {
		error(agenda.status || 502, 'Não foi possível carregar a agenda.');
	}

	return {
		...comum,
		appointments: agenda.data.appointments ?? [],
		professionals: agenda.data.professionals ?? [],
		appointmentTypes: agenda.data.appointment_types ?? [],
		patients: agenda.data.patients ?? [],
		availability,
		days: [] as DayCount[],
		agora: agenda.data.agora,
		timezone: agenda.data.timezone,
		// O "hoje" da tela sai do relógio que veio NA RESPOSTA, não do `me`. O `me` é carregado
		// pelo layout, e o SvelteKit não reexecuta load de layout em navegação client-side
		// (`goto`) — um `today` derivado dali congelaria no instante em que a aba abriu, e uma
		// aba atravessando a meia-noite passaria a marcar "Hoje" no dia errado.
		today: todayInZone(agenda.data.agora, agenda.data.timezone)
	};
};

// O paciente de `?paciente=<id>`, no formato que o picker do modal entende.
//
// Degrada para `null` em tudo — id ausente, malformado, de outra clínica, sem permissão: uma URL
// com paciente inválido abre a agenda normalmente, sem modal. Este parâmetro é conveniência de
// navegação, e conveniência não derruba tela.
async function carregarPreset(
	event: Parameters<PageServerLoad>[0]
): Promise<AgendaPatient | null> {
	const id = event.url.searchParams.get('paciente');
	if (!id) return null;

	const { patient } = await fetchPatient(event, id);
	if (!patient) return null;

	return {
		id: patient.id,
		nome: patient.nome,
		tel: patient.tel,
		ativo: patient.ativo,
		cor_indice: patient.cor_indice,
		...(patient.faltas != null ? { faltas: patient.faltas } : {})
	};
}

// A janela de cada visão de contagem. As duas saem de `$lib/agenda-views`, que é a casa das
// grades de calendário — o Mês reimplementava a aritmética aqui, fora do módulo e fora da
// justificativa que ele documenta para fazer tudo em UTC.
function janela(view: AgendaView, date: string): { from: string; to: string } {
	if (view !== 'semana') return monthWindow(date);

	const dias = weekDays(date);
	return { from: dias[0], to: dias[6] };
}

async function carregarContagens(
	event: Parameters<PageServerLoad>[0],
	view: AgendaView,
	date: string
) {
	const counts = await fetchCounts(event, janela(view, date));

	// Não degrada para dias vazios: a barra é o conteúdo destas visões, e um mês inteiro
	// zerado afirmaria que não há agenda nenhuma — o que não parece falha, parece dado.
	if (!counts.data) {
		error(counts.status || 502, 'Não foi possível carregar a agenda.');
	}

	return {
		days: counts.data.days ?? [],
		appointments: [],
		professionals: counts.data.professionals ?? [],
		appointmentTypes: [],
		patients: [],
		availability: [] as ColumnAvailability[],
		agora: counts.data.agora,
		timezone: counts.data.timezone,
		today: todayInZone(counts.data.agora, counts.data.timezone)
	};
}

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
async function carregarDia(event: Parameters<PageServerLoad>[0], date: string, view: AgendaView) {
	const agenda = await fetchAgenda(event, { from: date, to: date });
	if (!agenda.data) return { agenda, availability: [] as ColumnAvailability[] };

	// A hachura é geometria do grid, e a Lista não tem grid: pedir expediente ali seria um
	// round-trip que ninguém consome.
	if (view === 'lista') return { agenda, availability: [] as ColumnAvailability[] };

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
	const availability = profs.map((p): ColumnAvailability => ({
		professional_id: p.id,
		...(porProfissional.get(p.id) ?? { date, periods: [] })
	}));

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
	},

	// ---- Ciclo de vida (Entrega 4) ----
	//
	// Uma action por transição, todas com o mesmo formato de retorno (`ok`/`action` ou `fail`
	// com `error`/`code`). O `expected_version` é o guard de 409: o cliente manda o `version`
	// que leu, e a API recusa se o mundo mudou. As mutações do drawer e o arraste usam estas
	// mesmas actions (o arraste submete a `?/remarcar` programaticamente).

	remarcar: async (event) => {
		const s = await submission(event, 'remarcar');
		if (!('id' in s)) return s;
		const { form, id } = s;

		const starts_at = String(form.get('starts_at') ?? '');
		if (!Number.isFinite(Date.parse(starts_at))) {
			return fail(400, { action: 'remarcar', error: 'Escolha uma data e um horário válidos.' });
		}

		const professional_id = String(form.get('professional_id') ?? '');

		return finish(
			'remarcar',
			await rescheduleAppointment(event, id, {
				starts_at,
				...(professional_id ? { professional_id } : {}),
				// Só viaja quando a recepção escreveu algo: `""` gravaria string vazia onde o
				// "não informado" é `null`, e o relatório contaria motivo em branco como motivo
				// (mesma regra do `motivo` da falta).
				...(String(form.get('reschedule_reason') ?? '').trim() !== ''
					? { reschedule_reason: String(form.get('reschedule_reason')).trim() }
					: {}),
				encaixe: form.get('encaixe') === 'on' || form.get('encaixe') === 'true',
				expected_version: expectedVersion(form)
			})
		);
	},

	reabrir: (event) => transition(event, 'reabrir', (e, id, v) => reopenAppointment(e, id, v)),
	// Soft-delete (doc 40): mesma forma de reabrir (id + versão), sem corpo próprio.
	excluir: (event) => transition(event, 'excluir', (e, id, v) => excludeAppointment(e, id, v)),

	cancelar: async (event) => {
		const s = await submission(event, 'cancelar');
		if (!('id' in s)) return s;
		const { form, id } = s;

		const cancel_reason = String(form.get('cancel_reason') ?? '').trim();

		return finish(
			'cancelar',
			await cancelAppointment(event, id, {
				...(cancel_reason ? { cancel_reason } : {}),
				expected_version: expectedVersion(form)
			})
		);
	},


	// Presença por participante (A2, doc 41): uma action só para os quatro verbos, porque a
	// diferença entre eles é o segmento da rota — não o fluxo. `patient_id` e `kind` vêm do form;
	// `kind` é validado contra a lista, senão o campo do cliente escolheria o caminho da URL.
	presenca: async (event) => {
		const s = await submission(event, 'presenca');
		if (!('id' in s)) return s;
		const { form, id } = s;

		const patient_id = String(form.get('patient_id') ?? '');
		const kind = String(form.get('kind') ?? '');

		if (!patient_id || !PARTICIPANT_KINDS.includes(kind as ParticipantKind)) {
			return fail(400, { action: 'presenca', error: 'Participante ou ação não informados.' });
		}

		return finish(
			'presenca',
			await transitionParticipant(event, id, patient_id, kind as ParticipantKind, {
				expected_version: expectedVersion(form),
				...(kind === 'justify'
					? { justificada: form.get('justificada') === 'true' || form.get('justificada') === 'on' }
					: {}),
				// D-H3/D5: só a falta carrega motivo, e só quando a recepção escreveu algo. Mandar
				// `""` gravaria string vazia onde o "não informado" é `null` — e o relatório
				// passaria a contar motivo em branco como motivo preenchido.
				...(kind === 'no_show' && String(form.get('motivo') ?? '').trim() !== ''
					? { motivo: String(form.get('motivo')).trim() }
					: {})
			})
		);
	},

	// Enviar (ou reenviar) a confirmação ao paciente (doc 52 §6). O botão do rodapé do drawer
	// deixou de ser um toast que mentia e passa por aqui.
	//
	// `patient_id` é opcional e recorta um participante: numa turma, reenviar para quem falhou
	// não pode disparar para os outros três.
	//
	// **O 201 não é a resposta**: a API aceita o pedido e devolve o resultado por participante,
	// que pode ser "pulado" (sem contato, canal desligado, opt-out). Enquanto isto virava sucesso
	// pelo status, a recepção clicava, lia "Feito" e nada saía — silêncio disfarçado de envio, o
	// contrário do que a timeline inteira existe para fazer.
	confirmar: async (event) => {
		const s = await submission(event, 'confirmar');
		if (!('id' in s)) return s;

		const patientId = String(s.form.get('patient_id') ?? '') || undefined;
		const enviado = await sendConfirmation(event, s.id, patientId);
		if (!enviado.ok) return finish('confirmar', enviado);

		const mensagem = textoDoEnvio(enviado.resultados);

		// Ninguém recebeu: é um resultado que a recepção precisa LER, não um sucesso silencioso.
		// O 422 aqui é o do form, não o da API — o que ele carrega é a explicação.
		if (!enviado.resultados.some((r) => r.enviado)) {
			return fail(422, { action: 'confirmar', error: mensagem });
		}

		// Sucesso (inclusive o parcial da turma): a mensagem diz para quantos saiu e por que o
		// resto ficou de fora.
		return { ok: true, action: 'confirmar', mensagem };
	},

	// AN-12 (doc 64, D11): agendar um candidato da fila NA vaga que abriu. É a MESMA conversão
	// da tela da fila (`?/converter`), mas o slot não é escolhido — é o do próprio bloco
	// (cancelado/faltou) de onde o drawer partiu. O `id` aqui é o item da FILA, não o bloco;
	// por isso não usa o `submission/2` (a mensagem de erro falaria do agendamento errado).
	agendar_fila: async (event) => {
		const form = await event.request.formData();

		const id = String(form.get('id') ?? '');
		if (!id) return fail(400, { action: 'agendar_fila', error: 'Item da fila não informado.' });

		const starts_at = String(form.get('starts_at') ?? '');
		if (!Number.isFinite(Date.parse(starts_at))) {
			return fail(400, { action: 'agendar_fila', error: 'A vaga não tem um horário válido.' });
		}

		const professional_id = String(form.get('professional_id') ?? '');
		const appointment_type_id = String(form.get('appointment_type_id') ?? '');
		if (!professional_id || !appointment_type_id) {
			return fail(400, { action: 'agendar_fila', error: 'A vaga não tem profissional ou tipo.' });
		}

		const duracao = Number(form.get('duration_minutos'));

		return finish(
			'agendar_fila',
			await convertEntry(event, id, {
				starts_at,
				professional_id,
				appointment_type_id,
				// A falta ocupa o horário para a exclusion constraint (`status <> 'cancelado'`):
				// cobrir vaga de falta só entra como encaixe, e o drawer manda o flag já armado.
				encaixe: form.get('encaixe') === 'on' || form.get('encaixe') === 'true',
				...(Number.isFinite(duracao) && duracao > 0 ? { duration_minutos: duracao } : {})
			})
		);
	}
};

// Lê o corpo e exige o `id` do agendamento — o preâmbulo que as quatro actions de ciclo de
// vida com corpo próprio repetiam. Devolve `{form, id}` OU o `fail(400)` pronto (o chamador
// faz `if (!('id' in s)) return s`). O `transition/3` abaixo (transições sem corpo) usa o mesmo.
async function submission(event: Parameters<Actions[string]>[0], action: string) {
	const form = await event.request.formData();
	const id = String(form.get('id') ?? '');
	if (!id) return fail(400, { action, error: 'Agendamento não informado.' });
	return { form, id };
}

// Molde comum das transições sem corpo próprio (concluir/faltar/reabrir): id + versão.
async function transition(
	event: Parameters<Actions[string]>[0],
	action: string,
	run: (event: Parameters<Actions[string]>[0], id: string, version: number) => Promise<MutationResult>
) {
	const s = await submission(event, action);
	if (!('id' in s)) return s;
	return finish(action, await run(event, s.id, expectedVersion(s.form)));
}

function expectedVersion(form: FormData): number {
	const v = Number(form.get('expected_version'));
	return Number.isFinite(v) ? v : 0;
}

