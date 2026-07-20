<script lang="ts">
	// Agenda (doc 25, Entregas 1 e 2). Quatro visões: Dia e Lista leem blocos do dia; Semana e
	// Mês leem contagens. Remarcar, arrastar e mudar status são a Entrega 4.
	import { untrack } from 'svelte';
	import { goto, invalidate } from '$app/navigation';
	import { page as pageState } from '$app/state';
	import AgendaNav from '$lib/components/agenda/AgendaNav.svelte';
	import DayGrid from '$lib/components/agenda/DayGrid.svelte';
	import WeekView from '$lib/components/agenda/WeekView.svelte';
	import MonthView from '$lib/components/agenda/MonthView.svelte';
	import ListView from '$lib/components/agenda/ListView.svelte';
	import NewAppointmentModal from '$lib/components/agenda/NewAppointmentModal.svelte';
	import { toast } from '$lib/toast.svelte';
	import {
		canCreateAppointment,
		patientNameMap,
		type SearchResult,
		type Appointment,
		type AgendaPatient
	} from '$lib/agenda';
	import { agendaTopics, connectAgenda, type RealtimeConfig } from '$lib/realtime';
	import { applyAppointment, mergePatients } from '$lib/agenda-live';
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
	const topicsKey = $derived(
		realtime ? agendaTopics(realtime.clinic_id, data.view as AgendaView, data.date).join('|') : ''
	);

	$effect(() => {
		const key = topicsKey;
		if (!key) return;

		// Fora do rastreamento: `realtime` já entra pela chave acima, e lê-lo aqui só
		// acrescentaria uma reconexão por renovação de token.
		const cfg = untrack(() => realtime);
		if (!cfg) return;

		return connectAgenda(cfg, key.split('|'), {
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
					appointments: applyAppointment(
						live?.appointments ?? data.appointments,
						evento.appointment
					),
					patients: mergePatients(live?.patients ?? data.patients, evento.patients ?? [])
				};
			},
			onSignal: recarregar,
			onResync: recarregar
		});
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

	// O drawer do agendamento é da Entrega 4 (ciclo de vida). Até lá, selecionar não faz nada —
	// melhor que abrir um painel vazio. Um ponto só, porque o grid e a lista selecionam igual.
	function selecionar(_id: string) {}

	async function search(q: string): Promise<SearchResult> {
		const res = await fetch(`/agenda/pacientes?q=${encodeURIComponent(q)}`);
		if (!res.ok) return { patients: [], total: 0 };
		return (await res.json()) as SearchResult;
	}

	// Resultado da action `criar`. O erro NÃO fecha o modal: é lá dentro que mora a saída
	// ("marcar como encaixe"), e fechar jogaria fora o que a pessoa já preencheu.
	$effect(() => {
		if (!form) return;
		if (form.ok && form.action === 'criar') {
			modal = null;
			toast('Agendamento criado');
		}
	});
</script>

<div class="flex h-full flex-col">
	<AgendaNav
		date={data.date}
		today={data.today}
		view={data.view as AgendaView}
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
