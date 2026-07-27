<script lang="ts">
	// Agenda (doc 25, Entregas 1 e 2). Quatro visões: Dia e Lista leem blocos do dia; Semana e
	// Mês leem contagens. Remarcar, arrastar e mudar status são a Entrega 4.
	import { untrack } from 'svelte';
	import { goto, invalidate, invalidateAll } from '$app/navigation';
	import { deserialize } from '$app/forms';
	import { page as pageState } from '$app/state';
	import AgendaNav from '$lib/components/agenda/AgendaNav.svelte';
	import DayGrid from '$lib/components/agenda/DayGrid.svelte';
	import WeekView from '$lib/components/agenda/WeekView.svelte';
	import MonthView from '$lib/components/agenda/MonthView.svelte';
	import ListView from '$lib/components/agenda/ListView.svelte';
	import NewAppointmentModal from '$lib/components/agenda/NewAppointmentModal.svelte';
	import AppointmentDrawer from '$lib/components/agenda/AppointmentDrawer.svelte';
	import RescheduleModal from '$lib/components/agenda/RescheduleModal.svelte';
	import { toast } from '$lib/toast.svelte';
	import {
		canCreateAppointment,
		canCreateEncaixe,
		patientNameMap,
		toUtcIso,
		type SearchResult,
		type Appointment,
		type AgendaPatient
	} from '$lib/agenda';
	import type { ActionResult } from '@sveltejs/kit';
	import {
		agendaTopics,
		connectAgenda,
		type AgendaMode,
		type RealtimeConfig
	} from '$lib/realtime';
	import { applyToDay, mergePatients } from '$lib/agenda-live';
	import { viewRendersCounts } from '$lib/agenda-views';
	import ProfessionalChips from '$lib/components/agenda/ProfessionalChips.svelte';
	import { mediaQuery, AGENDA_MOBILE } from '$lib/media.svelte';
	import type { AgendaView } from '$lib/agenda-views';
	import type { PageData } from './$types';

	let { data, form }: { data: PageData; form: Record<string, unknown> | null } = $props();

	const podeCriar = $derived(canCreateAppointment(data.me?.papel));

	// Mesmo helper de estado-na-URL de `pacientes/+page.svelte:53`: aplica um patch na query
	// string e navega sem empilhar histórico.
	function navigate(patch: Record<string, string | null>) {
		const params = new URLSearchParams(pageState.url.searchParams);
		for (const [key, value] of Object.entries(patch)) {
			if (value === null || value === '') params.delete(key);
			else params.set(key, value);
		}
		const qs = params.toString();
		goto(qs ? `/agenda?${qs}` : '/agenda', { keepFocus: true, noScroll: true, replaceState: true });
	}

	// ---- Tempo real (Entrega 3, ADR-004) --------------------------------------------------
	//
	// O que a tela mostra é `data` do load COM o patch dos eventos por cima. `live` é esse
	// patch, e ele é jogado fora a cada dado novo do servidor: o REST é a fonte de verdade e o
	// evento é otimização sobre ele (09 §7.5), nunca o contrário.
	let live = $state<{ appointments: Appointment[]; patients: AgendaPatient[] } | null>(null);
	let realtime = $state<RealtimeConfig | null>(null);
	// F5 — os nomes de quem MAIS está vendo este dia (já sem o próprio usuário).
	let viewers = $state<string[]>([]);

	const appointments = $derived(live?.appointments ?? data.appointments);
	const patients = $derived(live?.patients ?? data.patients);

	$effect(() => {
		// Lido para criar a dependência: qualquer carga nova descarta o patch acumulado.
		data.appointments;
		data.patients;
		live = null;
	});

	// O token do socket, uma vez por aba. Vem do BFF (o cookie de sessão é HttpOnly) junto da
	// origem pública da API — o WebSocket é a exceção ao ADR-005 e fala direto com o Phoenix.
	// Sem token a agenda continua funcionando, só não atualiza sozinha.
	$effect(() => {
		let vivo = true;

		fetch('/api/realtime/token')
			.then((r) => (r.ok ? r.json() : null))
			.then((cfg) => {
				if (vivo && cfg?.token) realtime = cfg as RealtimeConfig;
			})
			.catch(() => {});

		return () => {
			vivo = false;
		};
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

	// ---- Ciclo de vida (Entrega 4) ----------------------------------------------------------
	//
	// O drawer abre ao selecionar um bloco; a remarcação abre por cima dele (ou pelo arraste).
	// `selecionado` é DERIVADO da lista atual (já com o patch de tempo real): quando uma mutação
	// reexecuta o load, o bloco no drawer reflete o novo estado sem fechar — e um bloco que
	// desaparecer da janela fecha o drawer sozinho, em vez de mostrar um estado congelado.
	let selectedId = $state<string | null>(null);
	let remarcando = $state(false);

	const selecionado = $derived(appointments.find((a) => a.id === selectedId) ?? null);

	// O drawer fecha sozinho se o bloco saiu da janela (remarcado para outro dia, por exemplo).
	$effect(() => {
		if (selectedId && !selecionado) {
			selectedId = null;
			remarcando = false;
		}
	});

	const selTipo = $derived(
		selecionado ? data.appointmentTypes.find((t) => t.id === selecionado.appointment_type_id) : undefined
	);
	const selProf = $derived(
		selecionado ? data.professionals.find((p) => p.id === selecionado.professional_id) : undefined
	);

	function selecionar(id: string) {
		selectedId = id;
		remarcando = false;
	}

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

	async function search(q: string): Promise<SearchResult> {
		const res = await fetch(`/agenda/pacientes?q=${encodeURIComponent(q)}`);
		if (!res.ok) return { patients: [], total: 0 };
		return (await res.json()) as SearchResult;
	}

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
		justificar: 'Falta atualizada'
	};

	// Marcador "último form já tratado" — NÃO é `$state`: o efeito só depende de `form`. Como
	// `$state`, o efeito LIA e ESCREVIA `ultimoForm` (a guarda + a atribuição), e essa
	// autodependência estourava `effect_update_depth_exceeded` ao criar/remarcar — a modal
	// travava aberta e a tela inteira parava até um F5. Um `let` simples quebra o ciclo.
	let ultimoForm: unknown = null;
	$effect(() => {
		// Só reage a um resultado NOVO (o mesmo objeto não deve retoastar em rerender).
		if (!form || form === ultimoForm) return;
		ultimoForm = form;

		if (form.ok) {
			if (form.action === 'criar') modal = null;
			if (form.action === 'remarcar') {
				remarcando = false;
				dragConflito = null;
			}
			toast(SUCESSO[form.action as string] ?? 'Feito');
		} else if (form.action !== 'criar' && form.action !== 'remarcar') {
			// Erros de criar/remarcar aparecem DENTRO do modal (com a saída de encaixe). As demais
			// mutações não têm modal aberto — o erro (ex.: 409 "recarregue") vira toast.
			toast(String(form.error ?? 'Não foi possível concluir a ação.'));
		}
	});
</script>

<div class="flex h-full flex-col">
	<AgendaNav
		date={data.date}
		today={data.today}
		view={data.view as AgendaView}
		{viewers}
		onDate={(d) => navigate({ date: d })}
		onView={(v) => navigate({ view: v === 'dia' ? null : v })}
	/>

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
		onClose={() => (selectedId = null)}
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
