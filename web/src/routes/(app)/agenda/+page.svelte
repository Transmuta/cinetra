<script lang="ts">
	// Agenda (doc 25, Entregas 1 e 2). Quatro visões: Dia e Lista leem blocos do dia; Semana e
	// Mês leem contagens. Remarcar, arrastar e mudar status são a Entrega 4.
	import { untrack } from 'svelte';
	import { goto, invalidate, invalidateAll, pushState, replaceState } from '$app/navigation';
	import { deserialize } from '$app/forms';
	import { page as pageState } from '$app/state';
	import { reportar } from '$lib/report';
	import { criarAnunciante } from '$lib/anuncio.svelte';
	import AgendaNav from '$lib/components/agenda/AgendaNav.svelte';
	import AgendaLegend from '$lib/components/agenda/AgendaLegend.svelte';
	import DayGrid from '$lib/components/agenda/DayGrid.svelte';
	import WeekView from '$lib/components/agenda/WeekView.svelte';
	import MonthView from '$lib/components/agenda/MonthView.svelte';
	import ListView from '$lib/components/agenda/ListView.svelte';
	import NewAppointmentModal from '$lib/components/agenda/NewAppointmentModal.svelte';
	import AppointmentDrawer from '$lib/components/agenda/AppointmentDrawer.svelte';
	import type { MessageParticipant, MessagesData } from '$lib/messages';
	import type { CandidatesResponse, Entry } from '$lib/waitlist';
	import RescheduleModal from '$lib/components/agenda/RescheduleModal.svelte';
	import { toast } from '$lib/toast.svelte';
	import { reagirAoForm } from '$lib/forms.svelte';
	import {
		canCreateAppointment,
		canCreateEncaixe,
		patientNameMap,
		presetDoBotao,
		toUtcIso,
		type Appointment,
		type AgendaPatient
	} from '$lib/agenda';
	import { buscarPacientes } from '$lib/patient-search-client';
	import type { ActionResult } from '@sveltejs/kit';
	import { agendaTopics, connectAgenda, type AgendaMode } from '$lib/realtime';
	import { usarTokenRealtime } from '$lib/realtime-token.svelte';
	import { applyToDay, mergePatients } from '$lib/agenda-live';
	import { viewRendersCounts } from '$lib/agenda-views';
	import ProfessionalChips from '$lib/components/agenda/ProfessionalChips.svelte';
	import { mediaQuery, AGENDA_MOBILE } from '$lib/media.svelte';
	import type { AgendaView } from '$lib/agenda-views';
	import type { PageData } from './$types';

	let { data, form }: { data: PageData; form: Record<string, unknown> | null } = $props();

	const podeCriar = $derived(canCreateAppointment(data.me?.papel));

	// A query atual com um patch aplicado — só a FORMA da URL, sem decidir como navegar. Dois
	// consumidores com necessidades opostas: `navigate` precisa reexecutar o load (mudou o dia,
	// mudou o dado), e o drawer precisa NÃO reexecutar (ver `selecionar`).
	function urlCom(patch: Record<string, string | null>): string {
		const params = new URLSearchParams(pageState.url.searchParams);
		for (const [key, value] of Object.entries(patch)) {
			if (value === null || value === '') params.delete(key);
			else params.set(key, value);
		}
		const qs = params.toString();
		return qs ? `/agenda?${qs}` : '/agenda';
	}

	// Mesmo helper de estado-na-URL de `pacientes/+page.svelte:53`: aplica um patch na query
	// string e navega sem empilhar histórico.
	//
	// Sempre larga o `agendamento`: trocar de dia, de visão ou de colunas fecha o drawer — o
	// bloco aberto é do dia que estava na tela. Sem isto o id sobreviveria à navegação e o
	// drawer tentaria abrir um bloco que não está mais na janela.
	function navigate(patch: Record<string, string | null>) {
		goto(urlCom({ ...patch, agendamento: null }), {
			keepFocus: true,
			noScroll: true,
			replaceState: true
		});
	}

	// ---- Tempo real (Entrega 3, ADR-004) --------------------------------------------------
	//
	// O que a tela mostra é `data` do load COM o patch dos eventos por cima. `live` é esse
	// patch, e ele é jogado fora a cada dado novo do servidor: o REST é a fonte de verdade e o
	// evento é otimização sobre ele (09 §7.5), nunca o contrário.
	let live = $state<{ appointments: Appointment[]; patients: AgendaPatient[] } | null>(null);
	// Sem token a agenda continua funcionando, só não atualiza sozinha — e a falha é reportada, não
	// engolida: dois atendentes vendo estados diferentes da mesma agenda é o que o tempo real
	// existe para evitar (doc 62 §7.2).
	const token = usarTokenRealtime();
	const realtime = $derived(token.cfg);
	// F5 — os nomes de quem MAIS está vendo este dia (já sem o próprio usuário).
	let viewers = $state<string[]>([]);
	// ACC-06 (doc 83): a grade muda sozinha por WebSocket e nada anunciava isso.
	const anunciante = criarAnunciante();

	const appointments = $derived(live?.appointments ?? data.appointments);
	const patients = $derived(live?.patients ?? data.patients);

	$effect(() => {
		// Lido para criar a dependência: qualquer carga nova descarta o patch acumulado.
		data.appointments;
		data.patients;
		live = null;
	});

	// Recarrega a janela visível. Semana e Mês vivem de contagem agregada, que não dá para
	// remendar a partir de um bloco (não dá para recalcular `capacidade_minutos` de um evento);
	// e é este também o caminho de ressincronização depois de reconectar.
	//
	// Com atraso, e cancelando o anterior: uma rajada de escritas (recepção marcando cinco
	// horários seguidos) vira UMA recarga. Não é polimento — a leitura de janela ainda varre o
	// histórico da clínica (achado (a) do doc 27), então cada recarga é cara.
	let recarga: ReturnType<typeof setTimeout> | null = null;

	function recarregar() {
		if (recarga) clearTimeout(recarga);
		recarga = setTimeout(() => {
			recarga = null;
			void invalidate('agenda:dados');
		}, 400);
	}

	// A conexão depende dos TÓPICOS, não de `data`. A diferença aparece só ao vivo, no log do
	// servidor: um efeito que lê `data.view`/`data.date` direto re-executa a cada carga nova —
	// e como o sinal do Mês chama `invalidate`, cada evento derrubava e reabria o WebSocket.
	// Funcionava, e era churn puro. A chave é string: o `$derived` só notifica quando ela MUDA
	// de fato, então recarregar o mesmo dia não mexe na conexão.
	//
	// O MODO entra na chave junto dos tópicos (D-G/D-H): quem renderiza contagem pede `signal`
	// e o servidor deixa de reler o bloco só para o cliente descartá-lo. É o MESMO predicado
	// que decide, logo abaixo, remendar × recarregar — as duas decisões não podem divergir.
	const modo = $derived(viewRendersCounts(data.view as AgendaView) ? 'signal' : 'block');

	const topicsKey = $derived(
		realtime
			? [modo, ...agendaTopics(realtime.clinic_id, data.view as AgendaView, data.date)].join('|')
			: ''
	);

	$effect(() => {
		const key = topicsKey;
		if (!key) return;

		// Fora do rastreamento: `realtime` já entra pela chave acima, e lê-lo aqui só
		// acrescentaria uma reconexão por renovação de token.
		const cfg = untrack(() => realtime);
		if (!cfg) return;

		const [mode, ...topics] = key.split('|');

		return connectAgenda(
			cfg,
			topics,
			{
				onAppointment: (evento) => {
					// ACC-06 (doc 83): a grade se reescrevia em silêncio. Uma frase genérica, e não o
					// detalhe do bloco, porque o anúncio serve para dizer "olhe de novo" — quem quiser o
					// detalhe navega até ele. O `criarAnunciante` junta a rajada (um remarcar dispara
					// dois eventos), então dez pushes não viram dez falas.
					anunciante.anunciar('A agenda deste dia mudou.');

					// Semana assina tópicos de DIA (granularidade por dia), mas renderiza contagem:
					// o bloco não dá para remendar numa barra, então vira refetch — o mesmo caminho
					// que o sinal do Mês toma. Sem isto a barra da Semana ficava congelada (o bloco
					// ia para `live.appointments`, que a Semana não mostra). Dia e Lista remendam.
					if (viewRendersCounts(data.view as AgendaView)) {
						recarregar();
						return;
					}

					live = {
						// `applyToDay` (não `applyAppointment`): Dia e Lista mostram UM dia, e um
						// `appointment_rescheduled` que moveu o bloco para outro dia precisa REMOVÊ-lo
						// daqui — senão vira bloco fantasma (Entrega 4, doc 25 §9).
						appointments: applyToDay(
							live?.appointments ?? data.appointments,
							evento.appointment,
							data.date,
							data.timezone
						),
						patients: mergePatients(live?.patients ?? data.patients, evento.patients ?? [])
					};
				},
				onSignal: recarregar,
				// Soft-delete (doc 40): remove o bloco excluído por id. Só chega no modo `block`
				// (Dia/Lista); Semana/Mês recebem a exclusão como `onSignal`. O `selecionado`
				// derivado some junto → o drawer aberto naquele bloco fecha sozinho.
				onRemove: (id) => {
					if (viewRendersCounts(data.view as AgendaView)) {
						recarregar();
						return;
					}
					live = {
						appointments: (live?.appointments ?? data.appointments).filter((a) => a.id !== id),
						patients: live?.patients ?? data.patients
					};
				},
				onResync: recarregar,
				// F5 — quem mais está com este dia aberto. Só Dia/Lista recebem: o servidor não
				// rastreia presença nos tópicos que renderizam contagem.
				onViewers: (nomes) => (viewers = nomes)
			},
			{ mode: mode as AgendaMode, userId: data.me?.user?.id ?? null }
		);
	});

	// Trocar de dia/visão zera a lista: a presença do dia anterior não vale para o novo, e o
	// `presence_state` do tópico novo só chega depois do join.
	$effect(() => {
		topicsKey;
		viewers = [];
	});

	// Nome do paciente por id, do sidecar `patients` do GET. O mapa é montado por
	// `patientNameMap` (pura, testada) e não aqui: é lá que fica registrado que arquivado
	// TAMBÉM entra. Sai de `patients` (já com o patch), não de `data.patients`: um bloco que
	// chega por evento pode citar alguém que a janela carregada não conhecia.
	const patientNames = $derived(patientNameMap(patients));

	// Mobile: a visão Dia troca de render abaixo de 860px — uma coluna por vez (protótipo
	// :1703). É comportamento, não layout, então não dá para resolver com classe do Tailwind.
	const mobile = mediaQuery(AGENDA_MOBILE);

	const colunasVisiveis = $derived(data.professionals.filter((p) => !data.hidden.includes(p.id)));

	let profEscolhido = $state<string | null>(null);

	// A escolha do chip é de sessão, não da URL: some ao trocar de dia, e uma coluna que
	// desaparece (profissional ocultado, ou dia sem ele) volta para a primeira em vez de
	// deixar a tela vazia sem explicação.
	const profMobile = $derived(
		colunasVisiveis.some((p) => p.id === profEscolhido)
			? profEscolhido
			: (colunasVisiveis[0]?.id ?? null)
	);

	let modal = $state<{ professional_id: string; hora: string } | null>(null);

	// ACC-03 (doc 83): o preset do botão "Novo agendamento" — a regra é pura e testada em
	// `$lib/agenda`. `null` (todos os profissionais ocultos) tira o botão da barra: não há coluna
	// para pré-selecionar, e um modal sem coluna só empurraria o erro para o submit.
	const presetBotao = $derived(
		presetDoBotao(data.professionals, data.hidden ?? [], data.availability ?? [])
	);

	// `?paciente=<id>` — chegou do "Agendar" da ficha (doc 51 §L2). Abre o modal já com o paciente
	// escolhido; profissional e hora ficam em branco, como no protótipo, que também abria a partir
	// da ficha sem slot ([`:2756`]).
	//
	// `preAberto` faz disparar UMA vez: sem ele, fechar o modal e o efeito reavaliar (por qualquer
	// mudança de estado) o reabriria, e a tela ficaria impossível de fechar.
	let preAberto = $state(false);
	const presetPatient = $derived(data.presetPatient ?? null);

	$effect(() => {
		if (presetPatient && podeCriar && !preAberto) {
			preAberto = true;
			modal = { professional_id: '', hora: '' };
		}
	});

	// ---- Ciclo de vida (Entrega 4) ----------------------------------------------------------
	//
	// O drawer abre ao selecionar um bloco; a remarcação abre por cima dele (ou pelo arraste).
	// `selecionado` é DERIVADO da lista atual (já com o patch de tempo real): quando uma mutação
	// reexecuta o load, o bloco no drawer reflete o novo estado sem fechar — e um bloco que
	// desaparecer da janela fecha o drawer sozinho, em vez de mostrar um estado congelado.
	//
	// **Qual bloco está aberto viaja na URL** (`?agendamento=<id>`), para que o drawer seja
	// LINKÁVEL: `/agenda?agendamento=<id>` abre o bloco direto, e o load resolve o dia por ele
	// (ver `diaDoBloco` em `+page.server.ts`).
	//
	// Mas abrir e fechar é **shallow routing**, não `goto`: o load desta página lê
	// `url.searchParams`, então uma navegação de verdade refaria a busca do dia inteiro (agenda +
	// expediente de todas as colunas) a cada bloco aberto. E aí entra o detalhe que decide a forma
	// deste código: `pushState`/`replaceState` do Kit atualizam **`page.state`** e deliberadamente
	// **não** `page.url` — eles até guardam a URL da última navegação real para restaurá-la no
	// popstate (`client.js`, `PAGE_URL_KEY`). Ler só a URL faria o drawer nunca abrir no clique;
	// ler só o estado o faria nunca abrir pelo link (o servidor não pode mandar `page.state`).
	//
	// Então as duas fontes têm papéis distintos, e é a diferença entre `undefined` e `null` que as
	// combina:
	//
	//   * `undefined` — o shallow routing nunca falou deste bloco: vale a URL (o link recebido, e
	//     também o que o back/forward restaura, porque o popstate devolve o estado do histórico);
	//   * um id — foi aberto por clique;
	//   * `null` — foi FECHADO por clique. Precisa ser explícito: a URL "velha" que sobra em
	//     `page.url` ainda tem o parâmetro, e sem o `null` o drawer reabriria sozinho.
	const noEstado = $derived((pageState.state as { agendamento?: string | null }).agendamento);
	const selectedId = $derived(
		noEstado !== undefined ? noEstado : pageState.url.searchParams.get('agendamento')
	);
	let remarcando = $state(false);

	const selecionado = $derived(appointments.find((a) => a.id === selectedId) ?? null);

	function selecionar(id: string) {
		remarcando = false;

		// `date` viaja junto do id, e não é redundância: é o que FIXA o dia. Sem ele, uma
		// remarcação para outro dia reexecutaria o load, que resolveria o dia pelo bloco — e a
		// tela pularia de data no meio do atendimento. Com `date` na URL o bloco só sai da janela,
		// e o drawer fecha (que é o comportamento de sempre).
		const url = urlCom({ agendamento: id, date: data.date });

		// Abrir EMPILHA: o back fecha o drawer, que é o que se espera de um painel. Trocar de
		// bloco com ele já aberto REFINA a mesma tela, e empilhar aí faria o back passear pelos
		// blocos visitados antes de fechar — o I68 da paginação, em `querystring.ts`.
		if (selectedId) replaceState(url, { agendamento: id });
		else pushState(url, { agendamento: id });
	}

	// `date` fica (e entra, se o link canônico não a trazia): fechar o painel não é sair do dia que
	// está na tela — e sem ela um F5 depois de fechar cairia no hoje da clínica, não no dia aberto.
	function fecharDrawer() {
		remarcando = false;
		replaceState(urlCom({ agendamento: null, date: data.date }), { agendamento: null });
	}

	// O bloco pode sair da janela com o drawer aberto (remarcado para outro dia, excluído por
	// outra pessoa): `selecionado` vira `null` e o painel some sozinho. O que sobra a fazer é
	// largar a remarcação — e **nada de navegar aqui**: este efeito também roda na hidratação de
	// um link morto (bloco excluído, de outra clínica, do colega), e shallow routing antes de o
	// roteador iniciar é erro no console. O parâmetro órfão na URL não abre nada e se resolve no
	// próximo carregamento; é o mesmo tratamento do `?paciente=` inválido.
	$effect(() => {
		if (selectedId && !selecionado) remarcando = false;
	});

	const selTipo = $derived(
		selecionado ? data.appointmentTypes.find((t) => t.id === selecionado.appointment_type_id) : undefined
	);
	const selProf = $derived(
		selecionado ? data.professionals.find((p) => p.id === selecionado.professional_id) : undefined
	);

	// A timeline de comunicação (doc 52 §6), buscada quando o drawer abre — não no load da agenda.
	// Um dia cheio tem dezenas de blocos e o drawer mostra um; carregar a comunicação de todos
	// para exibir a de um multiplicaria o payload da tela mais usada (mesma razão do corte do Mês,
	// doc 25 §10).
	//
	// `null` = carregando, e é o que o drawer usa para não piscar "nada a mostrar" antes da
	// resposta.
	let mensagens = $state<MessageParticipant[] | null>(null);

	// A CHAVE do efeito é `selectedId` + a última action de confirmação: reexecutar depois de um
	// envio é o que faz a linha nova aparecer sem F5. Sem a segunda parte, a recepção clicaria em
	// "Enviar" e a timeline continuaria mostrando o estado de antes.
	//
	// A marca é um `$derived`, e não `form?.action === 'confirmar'` lido DENTRO do efeito, pela
	// mesma razão do `topicsKey` acima: ler o `form` no efeito o torna dependente do `form`
	// INTEIRO, e o `enhance` repõe esse objeto a cada mutação. Excluir/criar/concluir qualquer
	// coisa refazia a busca da timeline. O derivado só notifica quando o VALOR muda, então action
	// alheia não mexe nele.
	const marcaConfirmar = $derived(form?.action === 'confirmar' ? form : null);

	// BOOLEANO, e não o objeto `selecionado`: o tempo real troca a identidade do bloco a cada push,
	// e depender do objeto refaria a busca a cada evento sem nada ter mudado (é a mesma nota do
	// efeito de candidatos abaixo). Um derivado booleano só notifica quando VIRA.
	const abertoNaJanela = $derived(selecionado !== null);

	$effect(() => {
		const id = selectedId;
		const marca = marcaConfirmar;
		void marca;

		// O bloco tem de estar na janela, não basta o id: o `?agendamento=` fica ÓRFÃO na URL quando
		// ele sai dela (excluído aqui ou por outra pessoa) — o drawer fecha sozinho, mas ninguém
		// navega (ver o efeito de `remarcando` acima, e o porquê de não navegar). Sem esta guarda o
		// efeito seguia pedindo a timeline de um bloco que a API não vê, e cada pedido voltava 404 —
		// em rajada, uma por action, até trocar de dia ou dar F5. Pego ao vivo na HML.
		if (!id || !abertoNaJanela) {
			mensagens = null;
			return;
		}

		let vivo = true;
		mensagens = null;

		fetch(`/agenda/mensagens/${id}`)
			.then((r) => (r.ok ? r.json() : { participantes: [] }))
			.then((body: MessagesData) => {
				// Guarda contra resposta fora de ordem: abrir dois blocos rápido faria a resposta do
				// primeiro sobrescrever a do segundo.
				if (vivo && selectedId === id) mensagens = body.participantes ?? [];
			})
			.catch(() => {
				if (vivo && selectedId === id) mensagens = [];
			});

		return () => {
			vivo = false;
		};
	});

	// O "quem cabe aqui?" (AN-12, doc 64): buscado quando o drawer abre num bloco cuja vaga
	// ABRIU (cancelado/faltou) — sob demanda como as mensagens, e pela mesma razão de volume.
	//
	// As chaves do efeito são PRIMITIVAS do bloco (status/slot), não o objeto `selecionado`: o
	// tempo real troca o objeto a cada push, e a identidade nova refaria a consulta sem nada
	// ter mudado. A marca da action reexecuta depois de um "Agendar" — o convertido saiu da
	// fila e a lista precisa refletir isso sem F5. E ela é um `$derived` pelo mesmo motivo da
	// `marcaConfirmar` acima: lida dentro do efeito, ela arrastaria o `form` inteiro para a chave.
	let candidatos = $state<Entry[] | null>(null);

	const marcaAgendarFila = $derived(form?.action === 'agendar_fila' ? form : null);

	$effect(() => {
		const id = selectedId;
		const status = selecionado?.status;
		const prof = selecionado?.professional_id;
		const starts = selecionado?.starts_at;
		const ends = selecionado?.ends_at;
		const marca = marcaAgendarFila;
		void marca;

		const vagaAberta = status === 'cancelado' || status === 'faltou';
		if (!id || !vagaAberta || !prof || !starts || !ends) {
			candidatos = null;
			return;
		}

		let vivo = true;
		candidatos = null;

		const qs = new URLSearchParams({ professional_id: prof, starts_at: starts, ends_at: ends });
		fetch(`/agenda/candidatos?${qs}`)
			.then((r) => (r.ok ? r.json() : { candidates: [] }))
			.then((body: Partial<CandidatesResponse>) => {
				if (vivo && selectedId === id) candidatos = body.candidates ?? [];
			})
			.catch(() => {
				if (vivo && selectedId === id) candidatos = [];
			});

		return () => {
			vivo = false;
		};
	});

	// A seção só se aplica ao bloco de vaga aberta — `undefined` esconde a seção no drawer
	// (bloco agendado nem mostra "consultando").
	const candidatosDoDrawer = $derived(
		selecionado && (selecionado.status === 'cancelado' || selecionado.status === 'faltou')
			? candidatos
			: undefined
	);

	// Semente do modal quando o arraste cai num conflito (fluxo C). `null` = sem modal aberto por
	// arraste.
	let dragConflito = $state<{
		appt: Appointment;
		date: string;
		hora: string;
		profId: string;
		error?: string;
	} | null>(null);

	// Remarcar por arraste (Entrega 4). O arraste não abre modal, então submete a MESMA action
	// `?/remarcar` do drawer programaticamente. No conflito (fluxo C, protótipo `modalOverride`
	// :2294) NÃO é um beco sem saída: abre o RescheduleModal já no destino do arraste, com a
	// oferta de encaixe — a única saída real (RN-12: sem encaixe, nada sobrepõe). Demais erros
	// (fora do expediente, 409 "recarregue") viram toast e o bloco volta quando o load reexecuta.
	// A data nunca muda no arraste.
	async function dragReschedule(pre: { id: string; professional_id: string; hora: string }) {
		const appt = appointments.find((a) => a.id === pre.id);
		if (!appt) return;

		const starts_at = toUtcIso(data.date, pre.hora, data.timezone);
		if (starts_at === appt.starts_at && pre.professional_id === appt.professional_id) return;

		const body = new FormData();
		body.set('id', pre.id);
		body.set('starts_at', starts_at);
		body.set('professional_id', pre.professional_id);
		body.set('expected_version', String(appt.version));

		const res = await fetch('?/remarcar', { method: 'POST', body });
		const result = deserialize(await res.text()) as ActionResult;

		if (result.type === 'success') {
			toast('Remarcado');
			await invalidateAll();
		} else if (result.type === 'failure') {
			const d = result.data as { error?: string; code?: string } | undefined;
			if (d?.code === 'schedule_conflict' && canCreateEncaixe(data.me?.papel ?? null)) {
				dragConflito = {
					appt,
					date: data.date,
					hora: pre.hora,
					profId: pre.professional_id,
					error: d.error
				};
			} else {
				toast(String(d?.error ?? 'Não foi possível remarcar.'));
			}
		}
	}

	const search = (q: string) => buscarPacientes('/agenda/pacientes', q);

	// Resultado das actions. O erro NÃO fecha o modal: é lá dentro que mora a saída ("marcar
	// como encaixe"), e fechar jogaria fora o que a pessoa já preencheu. No sucesso, uma
	// mensagem por ação — o load já reexecutou (default do form action), então o drawer e o
	// grid refletem o novo estado sem trabalho extra aqui.
	const SUCESSO: Record<string, string> = {
		criar: 'Agendamento criado',
		remarcar: 'Remarcado',
		concluir: 'Sessão concluída',
		faltar: 'Falta registrada',
		cancelar: 'Agendamento cancelado',
		reabrir: 'Agendamento reaberto',
		justificar: 'Falta atualizada',
		// AN-12: o candidato da fila virou agendamento na vaga que abriu (e saiu da fila).
		agendar_fila: 'Agendado da fila'
	};

	// A guarda de "resultado novo" mora no `reagirAoForm` — inclusive a razão de ela ser um `let`
	// e não um `$state`, que aqui custou um `effect_update_depth_exceeded` com a modal travada.
	reagirAoForm(
		() => form,
		{
			sucesso: (f) => {
				if (f.action === 'criar') modal = null;
				if (f.action === 'remarcar') {
					remarcando = false;
					dragConflito = null;
				}
				// `mensagem` ganha do rótulo fixo: o envio de confirmação sabe coisas que a tabela
				// acima não pode saber — para quantos saiu, e por que o resto ficou de fora.
				toast(String(f.mensagem ?? SUCESSO[f.action as string] ?? 'Feito'));
			},
			// Erros de criar/remarcar aparecem DENTRO do modal (com a saída de encaixe). As demais
			// mutações não têm modal aberto — o erro (ex.: 409 "recarregue") vira toast.
			erro: (f) => {
				if (f.action === 'criar' || f.action === 'remarcar') return;
				toast(String(f.error ?? 'Não foi possível concluir a ação.'));
			}
		}
	);
</script>

<svelte:head><title>Agenda · Cinetra</title></svelte:head>

<!-- Anúncio das mudanças que chegam por WebSocket (ACC-06). Invisível: a mudança já está desenhada
     na grade — a região existe para que ela também chegue a quem não a vê. -->
<p class="sr-only" role="status" aria-live="polite">{anunciante.texto()}</p>

<div class="flex h-full flex-col">
	<AgendaNav
		date={data.date}
		today={data.today}
		view={data.view as AgendaView}
		{viewers}
		onDate={(d) => navigate({ date: d })}
		onView={(v) => navigate({ view: v === 'dia' ? null : v })}
		onNew={podeCriar && presetBotao ? () => (modal = presetBotao) : undefined}
	/>

	<!-- A legenda só vale onde o card existe: Dia e Lista consomem o `STATUS_META`; Semana e
	     Mês desenham ocupação, e uma legenda de status ali explicaria algo que não está na tela. -->
	{#if data.view !== 'semana' && data.view !== 'mes'}
		<AgendaLegend />
	{/if}

	<div class="min-h-0 flex-1 overflow-auto">
		{#if data.view === 'semana'}
			<WeekView
				date={data.date}
				today={data.today}
				days={data.days}
				professionals={data.professionals}
				hidden={data.hidden}
				onPick={(d) => navigate({ date: d, view: null })}
				onShowAll={() => navigate({ profs: null })}
			/>
		{:else if data.view === 'mes'}
			<MonthView
				date={data.date}
				today={data.today}
				days={data.days}
				professionals={data.professionals}
				hidden={data.hidden}
				onPick={(d) => navigate({ date: d, view: null })}
				onShowAll={() => navigate({ profs: null })}
			/>
		{:else if data.view === 'lista'}
			<ListView
				{appointments}
				professionals={data.professionals}
				appointmentTypes={data.appointmentTypes}
				{patientNames}
				timezone={data.timezone}
				hidden={data.hidden}
				onSelect={selecionar}
				onShowAll={() => navigate({ profs: null })}
			/>
		{:else}
			{#if mobile.current && colunasVisiveis.length > 1}
				<ProfessionalChips
					professionals={colunasVisiveis}
					selected={profMobile}
					onSelect={(id) => (profEscolhido = id)}
				/>
			{/if}

			<DayGrid
				date={data.date}
				today={data.today}
				timezone={data.timezone}
				agora={data.agora}
				{appointments}
				professionals={data.professionals}
				appointmentTypes={data.appointmentTypes}
				availability={data.availability}
				{patientNames}
				hidden={data.hidden}
				only={mobile.current ? profMobile : null}
				onShowAll={() => navigate({ profs: null })}
				onEmptyClick={(pre) => {
					if (podeCriar) modal = pre;
				}}
				onSelect={selecionar}
				onReschedule={podeCriar && !mobile.current ? dragReschedule : undefined}
			/>
		{/if}
	</div>
</div>

{#if modal && podeCriar}
	<NewAppointmentModal
		date={data.date}
		timezone={data.timezone}
		professionals={data.professionals}
		appointmentTypes={data.appointmentTypes}
		papel={data.me?.papel ?? null}
		preset={modal}
		pacientesIniciais={presetPatient ? [presetPatient] : []}
		{search}
		{form}
		onClose={() => (modal = null)}
	/>
{/if}

{#if selecionado}
	<AppointmentDrawer
		appt={selecionado}
		tipo={selTipo}
		professional={selProf}
		{patients}
		agora={data.agora}
		timezone={data.timezone}
		papel={data.me?.papel ?? null}
		{form}
		{mensagens}
		candidatos={candidatosDoDrawer}
		onClose={fecharDrawer}
		onReschedule={() => (remarcando = true)}
		onToast={(m) => toast(m)}
	/>

	{#if remarcando}
		<RescheduleModal
			appt={selecionado}
			timezone={data.timezone}
			professionals={data.professionals}
			papel={data.me?.papel ?? null}
			{form}
			onClose={() => (remarcando = false)}
		/>
	{/if}
{/if}

{#if dragConflito}
	<!-- Fluxo C: soltar o bloco caiu num conflito. O modal abre no destino do arraste, com a
	     saída de encaixe (protótipo `modalOverride` :2294). Fora do `{#if selecionado}` de
	     propósito — o arraste não abre o drawer atrás. -->
	<RescheduleModal
		appt={dragConflito.appt}
		timezone={data.timezone}
		professionals={data.professionals}
		papel={data.me?.papel ?? null}
		{form}
		initialDate={dragConflito.date}
		initialHora={dragConflito.hora}
		initialProfId={dragConflito.profId}
		initialConflict
		initialError={dragConflito.error}
		onClose={() => (dragConflito = null)}
	/>
{/if}
