<script lang="ts">
	// Agenda — visão Dia (doc 25, Entrega 1). Ler o dia e criar; remarcar, arrastar, mudar
	// status e as visões Semana/Mês/Lista são as entregas seguintes.
	import { goto } from '$app/navigation';
	import { page as pageState } from '$app/state';
	import AgendaNav from '$lib/components/agenda/AgendaNav.svelte';
	import DayGrid from '$lib/components/agenda/DayGrid.svelte';
	import NewAppointmentModal from '$lib/components/agenda/NewAppointmentModal.svelte';
	import { toast } from '$lib/toast.svelte';
	import { canCreateAppointment, patientNameMap, type SearchResult } from '$lib/agenda';
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

	let modal = $state<{ professional_id: string; hora: string } | null>(null);

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
	<AgendaNav date={data.date} today={data.today} onDate={(d) => navigate({ date: d })} />

	<div class="min-h-0 flex-1">
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
			onShowAll={() => navigate({ profs: null })}
			onEmptyClick={(pre) => {
				if (podeCriar) modal = pre;
			}}
			onSelect={() => {
				// O drawer do agendamento é da Entrega 4 (ciclo de vida). Até lá, selecionar
				// não faz nada — melhor que abrir um painel vazio.
			}}
		/>
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
