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
	import Check from '@lucide/svelte/icons/check';
	import Clock4 from '@lucide/svelte/icons/clock-4';
	import History from '@lucide/svelte/icons/history';
	import CalendarDays from '@lucide/svelte/icons/calendar-days';
	import CalendarRange from '@lucide/svelte/icons/calendar-range';
	import User from '@lucide/svelte/icons/user';
	import { PERIOD_LABELS, professionalName } from '$lib/reports';
	import { sectionOf, SECTION_TITLES, CONFIG_LINKS } from './nav';
	import { canViewAudit } from '$lib/audit';
	import { canManageProfessionals, countByStatus, type Professional } from '$lib/professionals';
	import { canManagePatients, type PatientCounts } from '$lib/patients';
	import {
		canManageWaitlist,
		priorityCounts,
		PRIORITY_META,
		type Entry,
		type PriorityFilter
	} from '$lib/waitlist';
	import { avatarColor } from '$lib/avatar';
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

	// Ícone de cada item de Configurações, por href (não por índice — a lista é filtrada por
	// papel, e um array paralelo desalinharia quando a Auditoria some para não-admin).
	const CONFIG_ICONS: Record<string, typeof Building2> = {
		'/configuracoes/clinica': Building2,
		'/configuracoes/tipos': Stethoscope,
		'/configuracoes/horario': Clock,
		'/configuracoes/excecoes': CalendarOff,
		'/configuracoes/equipe': SlidersHorizontal,
		'/configuracoes/auditoria': History
	};

	// A Auditoria é owner·admin: o link só aparece para quem pode entrar (a policy da API é a
	// autoridade — os demais levariam 403). Os outros itens são de todo membro.
	const configLinks = $derived(
		CONFIG_LINKS.filter((link) => !link.ownerAdmin || canViewAudit(page.data.me?.papel as Papel | null | undefined))
	);

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

	// Sidebar contextual da Fila (doc 25, Entrega 5). "Adicionar à fila" (viaja por `?novo=1`, o
	// gatilho que a página lê para abrir o modal) + o filtro por prioridade com contagens. Como na
	// agenda, é um ramo `if` explícito, não um default — cada seção nova declara a sua.
	const FILA_FILTERS: ReadonlyArray<{ key: PriorityFilter; label: string }> = [
		{ key: 'todas', label: 'Todas' },
		{ key: 'urgente', label: 'Urgente' },
		{ key: 'alta', label: 'Alta' },
		{ key: 'normal', label: 'Normal' },
		{ key: 'baixa', label: 'Baixa' }
	];
	const waitlist = $derived((page.data.waitlist as Entry[] | undefined) ?? []);
	const filaCounts = $derived(priorityCounts(waitlist));
	const canManageFila = $derived(canManageWaitlist(page.data.me?.papel as Papel | null | undefined));
	const filaPrio = $derived(page.url.searchParams.get('prio') ?? 'todas');
	const filaHref = (key: PriorityFilter) => (key === 'todas' ? '/fila' : `/fila?prio=${key}`);

	// Sidebar contextual da Agenda (doc 25 §6). No protótipo `sbAgenda()` é o ramo `default:`
	// de `sidebarBody` [:1407]; aqui é um `if` EXPLÍCITO por decisão — um default silencioso
	// faria toda seção futura (Fila, Relatórios) herdar a sidebar da agenda sem querer.
	//
	// O filtro por profissional é o ÚNICO da agenda (não há busca nem filtro por tipo/status)
	// e viaja em `?profs=` — a lista dos OCULTOS, para que a URL normal fique limpa. Tudo por
	// `<a>`: o estado mora na URL, como `?status=` e `?filter=` nas outras seções.
	const agendaProfs = $derived((page.data.professionals as Professional[] | undefined) ?? []);
	const agendaHidden = $derived((page.data.hidden as string[] | undefined) ?? []);
	const agendaDate = $derived((page.data.date as string | undefined) ?? '');

	// A query é montada à mão, e não com `URLSearchParams`, por um motivo só: ele escaparia a
	// vírgula de `profs=p1,p2` para `%2C`. A vírgula é legal num valor de query (RFC 3986) e
	// a URL da agenda é para ser lida e colada por gente.
	function agendaHref(hidden: string[]): string {
		const partes: string[] = [];
		if (agendaDate) partes.push(`date=${agendaDate}`);
		if (hidden.length) partes.push(`profs=${hidden.map(encodeURIComponent).join(',')}`);
		return partes.length ? `/agenda?${partes.join('&')}` : '/agenda';
	}

	// O link de cada linha leva ao estado RESULTANTE do clique: ocultar quem está visível,
	// revelar quem está oculto.
	const toggleHref = (id: string) =>
		agendaHref(
			agendaHidden.includes(id) ? agendaHidden.filter((x) => x !== id) : [...agendaHidden, id]
		);

	// Sidebar de Relatórios (doc 33 / `sbRelatorios` :1461): dois filtros — período e
	// profissional. Ambos viajam na URL (`?period=` / `?prof=`), como as outras seções; o load
	// os lê. A lista de profissionais vem do próprio relatório (`page.data.professionals`), então
	// para o papel `profissional` ela degenera nele mesmo e o filtro fica preso — o que a API já
	// impõe (§3).
	const relProfs = $derived((page.data.professionals as Professional[] | undefined) ?? []);
	const relPeriod = $derived(page.url.searchParams.get('period') ?? 'mes');
	const relProf = $derived(page.url.searchParams.get('prof') ?? 'todos');

	const REL_PERIODS = [
		{ key: 'hoje', icon: CalendarDays },
		{ key: 'semana', icon: CalendarRange },
		{ key: 'mes', icon: CalendarRange }
	] as const;

	// O link preserva o OUTRO filtro e omite os defaults ('mes' / 'todos') para a URL ficar limpa.
	function relHref(next: { period?: string; prof?: string }): string {
		const period = next.period ?? relPeriod;
		const prof = next.prof ?? relProf;
		const partes: string[] = [];
		if (period && period !== 'mes') partes.push(`period=${period}`);
		if (prof && prof !== 'todos') partes.push(`prof=${encodeURIComponent(prof)}`);
		return partes.length ? `/relatorios?${partes.join('&')}` : '/relatorios';
	}
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
			{#each configLinks as link (link.href)}
				{@const Icon = CONFIG_ICONS[link.href]}
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

	{#if section === 'agenda'}
		<div class="flex-1 overflow-auto px-3 py-1">
			<div
				class="flex items-center justify-between px-2 pb-1.5 pt-3 text-[10.5px] font-bold uppercase tracking-[.06em] text-faint"
			>
				<span>Profissionais</span>
				{#if agendaHidden.length}
					<a href={agendaHref([])} class="normal-case tracking-normal text-teal-text hover:underline">
						Mostrar todos
					</a>
				{/if}
			</div>

			{#if agendaProfs.length}
				{#each agendaProfs as prof (prof.id)}
					{@const oculto = agendaHidden.includes(prof.id)}
					<a
						href={toggleHref(prof.id)}
						aria-label="{oculto ? 'Mostrar' : 'Ocultar'} {prof.nome}"
						class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-[7px] text-[13px] hover:bg-surface-2 {oculto
							? 'text-faint'
							: 'font-medium text-ink'}"
					>
						<span
							class="grid size-4 shrink-0 place-items-center rounded border {oculto
								? 'border-edge-strong'
								: 'border-transparent text-white'}"
							style={oculto ? '' : `background:${avatarColor(prof.cor_indice)}`}
						>
							{#if !oculto}<Check size={11} />{/if}
						</span>
						<span class="flex-1 truncate">{prof.nome}</span>
					</a>
				{/each}
			{:else}
				<div class="px-2.5 py-2 text-[12.5px] text-faint">Nenhum profissional cadastrado.</div>
			{/if}
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

	{#if section === 'fila'}
		<div class="flex-1 overflow-auto px-3 py-1">
			{#if canManageFila}
				<a
					href="/fila?novo=1"
					class="mb-2 flex items-center justify-center gap-1.5 rounded-lg bg-ink px-3 py-2.5 text-[13px] font-semibold text-canvas hover:opacity-90"
				>
					<Plus size={15} /> Adicionar à fila
				</a>
			{/if}

			<div class="px-2 pb-1.5 pt-3 text-[10.5px] font-bold uppercase tracking-[.06em] text-faint">
				Prioridade
			</div>
			{#each FILA_FILTERS as fil (fil.key)}
				{@const isActive = filaPrio === fil.key}
				<a
					href={filaHref(fil.key)}
					aria-current={isActive ? 'page' : undefined}
					class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-[7px] text-[13px] {isActive
						? 'bg-surface-2 font-semibold text-ink'
						: 'font-medium text-muted hover:bg-surface-2'}"
				>
					<!-- Bolinha na cor da prioridade (hex fixo do protótipo); "Todas" leva o relógio. -->
					{#if fil.key === 'todas'}
						<span class={isActive ? 'text-teal-text' : 'text-faint'}><Clock4 size={15} /></span>
					{:else}
						<span class="grid size-[15px] place-items-center">
							<span class="size-2.5 rounded-full" style="background:{PRIORITY_META[fil.key].color}"></span>
						</span>
					{/if}
					<span class="flex-1 truncate">{fil.label}</span>
					<span class="font-mono text-[11px] text-faint">{filaCounts[fil.key]}</span>
				</a>
			{/each}
		</div>
	{/if}

	{#if section === 'relatorios'}
		<div class="flex-1 overflow-auto px-3 py-1">
			<div class="px-2 pb-1.5 pt-3 text-[10.5px] font-bold uppercase tracking-[.06em] text-faint">
				Período
			</div>
			{#each REL_PERIODS as per (per.key)}
				{@const isActive = relPeriod === per.key}
				<a
					href={relHref({ period: per.key })}
					aria-current={isActive ? 'page' : undefined}
					class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-[7px] text-[13px] {isActive
						? 'bg-surface-2 font-semibold text-ink'
						: 'font-medium text-muted hover:bg-surface-2'}"
				>
					<span class={isActive ? 'text-teal-text' : 'text-faint'}><per.icon size={15} /></span>
					<span class="flex-1 truncate">{PERIOD_LABELS[per.key]}</span>
				</a>
			{/each}

			<div class="px-2 pb-1.5 pt-3 text-[10.5px] font-bold uppercase tracking-[.06em] text-faint">
				Profissional
			</div>
			<a
				href={relHref({ prof: 'todos' })}
				aria-current={relProf === 'todos' ? 'page' : undefined}
				class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-[7px] text-[13px] {relProf ===
				'todos'
					? 'bg-surface-2 font-semibold text-ink'
					: 'font-medium text-muted hover:bg-surface-2'}"
			>
				<span class={relProf === 'todos' ? 'text-teal-text' : 'text-faint'}><Users size={15} /></span>
				<span class="flex-1 truncate">Todos</span>
			</a>
			{#each relProfs as prof (prof.id)}
				{@const isActive = relProf === prof.id}
				<a
					href={relHref({ prof: prof.id })}
					aria-current={isActive ? 'page' : undefined}
					class="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-[7px] text-[13px] {isActive
						? 'bg-surface-2 font-semibold text-ink'
						: 'font-medium text-muted hover:bg-surface-2'}"
				>
					<span class="grid size-4 shrink-0 place-items-center rounded-full text-white" style="background:{avatarColor(prof.cor_indice)}">
						<User size={10} />
					</span>
					<span class="flex-1 truncate">{professionalName(relProfs, prof.id)}</span>
				</a>
			{/each}
		</div>
	{/if}
</aside>
