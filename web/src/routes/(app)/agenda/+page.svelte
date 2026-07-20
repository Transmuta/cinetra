<script lang="ts">
	// Agenda (doc 25, Entregas 1 e 2). Quatro visões: Dia e Lista leem blocos do dia; Semana e
	// Mês leem contagens. Remarcar, arrastar e mudar status são a Entrega 4.
	import { goto } from '$app/navigation';
	import { page as pageState } from '$app/state';
	import AgendaNav from '$lib/components/agenda/AgendaNav.svelte';
	import DayGrid from '$lib/components/agenda/DayGrid.svelte';
	import WeekView from '$lib/components/agenda/WeekView.svelte';
	import MonthView from '$lib/components/agenda/MonthView.svelte';
	import ListView from '$lib/components/agenda/ListView.svelte';
	import NewAppointmentModal from '$lib/components/agenda/NewAppointmentModal.svelte';
	import { toast } from '$lib/toast.svelte';
	import { canCreateAppointment, patientNameMap, type SearchResult } from '$lib/agenda';
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

	// Nome do paciente por id, do sidecar `patients` do GET. O mapa é montado por
	// `patientNameMap` (pura, testada) e não aqui: é lá que fica registrado que arquivado
	// TAMBÉM entra.
	const patientNames = $derived(patientNameMap(data.patients));

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
				appointments={data.appointments}
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
				appointments={data.appointments}
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
