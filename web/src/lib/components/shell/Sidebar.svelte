<script lang="ts">
	import { page } from '$app/state';
	import MapPin from '@lucide/svelte/icons/map-pin';
	import Building2 from '@lucide/svelte/icons/building-2';
	import { maskCnpj } from '$lib/cnpj';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import Clock from '@lucide/svelte/icons/clock';
	import CalendarOff from '@lucide/svelte/icons/calendar-off';
	import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
	import Users from '@lucide/svelte/icons/users';
	import UserCheck from '@lucide/svelte/icons/user-check';
	import UserX from '@lucide/svelte/icons/user-x';
	import UserCog from '@lucide/svelte/icons/user-cog';
	import UserPlus from '@lucide/svelte/icons/user-plus';
	import Plus from '@lucide/svelte/icons/plus';
	import { sectionOf, SECTION_TITLES, CONFIG_LINKS } from './nav';
	import { canManageProfessionals, countByStatus, type Professional } from '$lib/professionals';
	import { canManagePatients, type PatientCounts } from '$lib/patients';
	import type { Papel } from '$lib/session';

	let {
		pathname,
		clinicName,
		clinicCnpj,
		clinicEndereco
	}: {
		pathname: string;
		clinicName?: string | null;
		clinicCnpj?: string | null;
		clinicEndereco?: string | null;
	} = $props();

	const section = $derived(sectionOf(pathname));
	const title = $derived(section ? SECTION_TITLES[section] : '');

	// Um ícone por item de Configurações, na mesma ordem de CONFIG_LINKS.
	const CONFIG_ICONS = [Building2, Stethoscope, Clock, CalendarOff, SlidersHorizontal, Users];

	// Sidebar contextual de Profissionais (profs.png): "Novo profissional" + FILTRAR com
	// contagens. Os dados vêm do load da rota (`page.data`), não de props — só existem quando a
	// seção é 'profissionais'. O filtro viaja por `?status=` (a lista o lê da URL).
	const PROF_FILTERS = [
		{ key: 'todos', label: 'Todos', icon: Users },
		{ key: 'ativos', label: 'Ativos', icon: UserCheck },
		{ key: 'inativos', label: 'Inativos', icon: UserX }
	] as const;
	const profs = $derived((page.data.professionals as Professional[] | undefined) ?? []);
	const profCounts = $derived(countByStatus(profs));
	const canManageProf = $derived(canManageProfessionals(page.data.me?.papel as Papel | null | undefined));
	const profStatus = $derived(page.url.searchParams.get('status') ?? 'todos');

	// Sidebar contextual de Pacientes: "Novo paciente" + FILTRAR. Eixo único (como o `pacFiltro`
	// do protótipo :1437): status + os segmentos calculáveis hoje (com responsável). Pacote/faltas
	// entram com F3/agenda. Viaja por `?filter=`; os dados vêm do load da lista (`page.data`).
	const PAT_FILTERS = [
		{ key: 'todos', label: 'Todos os pacientes', icon: Users },
		{ key: 'ativos', label: 'Ativos', icon: UserCheck },
		{ key: 'inativos', label: 'Inativos', icon: UserX },
		{ key: 'resp', label: 'Com responsável', icon: UserCog }
	] as const;
	// As contagens vêm do servidor (`page.data.counts`): a lista é paginada, então contar o que
	// chegou contaria só a página. Fora da seção Pacientes não há counts → tudo zero.
	const patCounts = $derived(
		(page.data.counts as PatientCounts | undefined) ?? { todos: 0, ativos: 0, inativos: 0, resp: 0 }
	);
	const canManagePat = $derived(canManagePatients(page.data.me?.papel as Papel | null | undefined));
	const patFilter = $derived(page.url.searchParams.get('filter') ?? 'todos');
</script>

<aside class="flex w-64 shrink-0 flex-col border-r border-edge bg-surface">
	<!-- Topo: identidade da clínica (o símbolo Cinetra vive no rail). Quando há nome, ele ocupa
	     o lugar da marca; CNPJ e endereço entram como subtítulo. Sem nome (borda), cai na marca. -->
	<div class="px-4 pb-1 pt-4">
		{#if clinicName}
			<div class="text-[17px] font-extrabold leading-tight tracking-tight">{clinicName}</div>
			{#if clinicCnpj}
				<div class="mt-1 font-mono text-[11px] text-faint">{maskCnpj(clinicCnpj)}</div>
			{/if}
			{#if clinicEndereco}
				<div class="mt-0.5 flex items-start gap-1.5 text-[12px] text-faint">
					<MapPin size={11} class="mt-0.75 shrink-0" />
					<span>{clinicEndereco}</span>
				</div>
			{/if}
		{:else}
			<span class="text-[17px] font-extrabold tracking-tight">Cinetra</span>
		{/if}
	</div>

	{#if title}
		<div class="flex items-center gap-1.5 px-4 pb-2 pt-2.5">
			<span class="text-[11px] font-bold uppercase tracking-[.06em] text-ink">{title}</span>
			<span class="size-[5px] rounded-full bg-teal"></span>
		</div>
	{/if}

	{#if section === 'config'}
		<nav aria-label="Configurações" class="flex-1 overflow-auto px-3 py-1">
			<div class="px-2 pb-1.5 pt-3 text-[10.5px] font-bold uppercase tracking-[.06em] text-faint">
				Ajustes
			</div>
			{#each CONFIG_LINKS as link, i (link.href)}
				{@const Icon = CONFIG_ICONS[i]}
				{@const isActive = pathname === link.href}
				<a
					href={link.href}
					aria-current={isActive ? 'page' : undefined}
					class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-[7px] text-[13px] {isActive
						? 'bg-surface-2 font-semibold text-ink'
						: 'font-medium text-muted hover:bg-surface-2'}"
				>
					<span class={isActive ? 'text-teal-text' : 'text-faint'}><Icon size={15} /></span>
					<span class="flex-1 truncate">{link.label}</span>
				</a>
			{/each}
		</nav>
	{/if}

	{#if section === 'profissionais'}
		<div class="flex-1 overflow-auto px-3 py-1">
			{#if canManageProf}
				<a
					href="/profissionais/novo"
					class="mb-2 flex items-center justify-center gap-1.5 rounded-lg bg-ink px-3 py-2.5 text-[13px] font-semibold text-canvas hover:opacity-90"
				>
					<Plus size={15} /> Novo profissional
				</a>
			{/if}

			<div class="px-2 pb-1.5 pt-3 text-[10.5px] font-bold uppercase tracking-[.06em] text-faint">
				Filtrar
			</div>
			{#each PROF_FILTERS as fil (fil.key)}
				{@const isActive = profStatus === fil.key}
				<a
					href="/profissionais?status={fil.key}"
					aria-current={isActive ? 'page' : undefined}
					class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-[7px] text-[13px] {isActive
						? 'bg-surface-2 font-semibold text-ink'
						: 'font-medium text-muted hover:bg-surface-2'}"
				>
					<span class={isActive ? 'text-teal-text' : 'text-faint'}><fil.icon size={15} /></span>
					<span class="flex-1 truncate">{fil.label}</span>
					<span class="font-mono text-[11px] text-faint">{profCounts[fil.key]}</span>
				</a>
			{/each}
		</div>
	{/if}

	{#if section === 'pacientes'}
		<div class="flex-1 overflow-auto px-3 py-1">
			{#if canManagePat}
				<a
					href="/pacientes/novo"
					class="mb-2 flex items-center justify-center gap-1.5 rounded-lg bg-ink px-3 py-2.5 text-[13px] font-semibold text-canvas hover:opacity-90"
				>
					<UserPlus size={15} /> Novo paciente
				</a>
			{/if}

			<div class="px-2 pb-1.5 pt-3 text-[10.5px] font-bold uppercase tracking-[.06em] text-faint">
				Segmentos
			</div>
			{#each PAT_FILTERS as fil (fil.key)}
				{@const isActive = patFilter === fil.key}
				<a
					href="/pacientes?filter={fil.key}"
					aria-current={isActive ? 'page' : undefined}
					class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-[7px] text-[13px] {isActive
						? 'bg-surface-2 font-semibold text-ink'
						: 'font-medium text-muted hover:bg-surface-2'}"
				>
					<span class={isActive ? 'text-teal-text' : 'text-faint'}><fil.icon size={15} /></span>
					<span class="flex-1 truncate">{fil.label}</span>
					<span class="font-mono text-[11px] text-faint">{patCounts[fil.key]}</span>
				</a>
			{/each}
		</div>
	{/if}
</aside>
