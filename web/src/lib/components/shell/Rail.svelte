<script lang="ts">
	import CalendarDays from '@lucide/svelte/icons/calendar-days';
	import Users from '@lucide/svelte/icons/users';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import Clock4 from '@lucide/svelte/icons/clock-4';
	import ChartBar from '@lucide/svelte/icons/chart-bar';
	// `ScrollText` (a trilha escrita), e não `History`: o relógio-com-seta do History é quase
	// igual ao `Clock4` da Fila de espera a 19px, e o rail tinha dois relógios vizinhos.
	import ScrollText from '@lucide/svelte/icons/scroll-text';
	import Settings from '@lucide/svelte/icons/settings';
	import Bell from '@lucide/svelte/icons/bell';
	import Mark from '$lib/components/Mark.svelte';
	import ThemeToggle from '$lib/components/ThemeToggle.svelte';
	import { canViewAudit } from '$lib/audit';
	import type { Papel } from '$lib/session';
	import { sectionOf, RAIL_ITEMS, type Section } from './nav';

	let {
		pathname,
		theme,
		unread = 0,
		papel = null
	}: {
		pathname: string;
		theme?: string | null;
		unread?: number;
		papel?: Papel | null;
	} = $props();

	const active = $derived(sectionOf(pathname));

	// A Auditoria é owner·admin: o ícone só aparece para quem pode entrar (a policy da API é a
	// autoridade — os demais levariam 403). Os outros destinos são de todo membro.
	const items = $derived(RAIL_ITEMS.filter((item) => !item.ownerAdmin || canViewAudit(papel)));
	const notificacoesActive = $derived(pathname.startsWith('/notificacoes'));
	// Cap visual do badge: acima de 9 vira "9+" (o número real está na tela).
	const badge = $derived(unread > 9 ? '9+' : String(unread));

	// `notificacoes` entra por completude do tipo: é seção (tem sidebar própria) mas NÃO é item
	// do rail — o acesso é o sino do rodapé, logo abaixo, e o `{#each RAIL_ITEMS}` nunca a lê.
	const ICONS: Record<Section, typeof CalendarDays> = {
		agenda: CalendarDays,
		pacientes: Users,
		profissionais: Stethoscope,
		fila: Clock4,
		relatorios: ChartBar,
		auditoria: ScrollText,
		config: Settings,
		notificacoes: Bell
	};
</script>

<nav
	aria-label="Navegação principal"
	class="flex w-14 shrink-0 flex-col items-center gap-1 bg-rail py-3"
>
	<!-- Marca Cinetra (símbolo) sobre ladrilho claro, p/ contraste no rail escuro. -->
	<!-- ACC-25 (doc 83): o nome saía só do `title`, que é mecanismo de ÚLTIMO recurso — e este é o
	     primeiro ponto de tabulação do app. O `aria-label` diz também para onde vai; o `title` fica
	     para o tooltip do mouse. -->
	<a
		href="/"
		title="Cinetra"
		aria-label="Cinetra — página inicial"
		class="mb-2.5 grid size-[34px] place-items-center rounded-[9px] bg-white"
	>
		<Mark class="size-6" />
	</a>

	{#each items as item (item.section)}
		{@const Icon = ICONS[item.section]}
		{@const isActive = active === item.section}
		<a
			href={item.href}
			title={item.label}
			aria-current={isActive ? 'page' : undefined}
			class="relative grid size-10 place-items-center rounded-lg transition-colors {isActive
				? 'bg-rail-item text-white'
				: 'text-white/60 hover:bg-rail-item/60 hover:text-white'}"
		>
			<Icon size={19} />
			{#if isActive}
				<span class="absolute right-1.5 top-1.5 size-[5px] rounded-full bg-accent"></span>
			{/if}
		</a>
	{/each}

	<div class="flex-1"></div>

	<!-- Notificações (doc 31): link para a caixa, com badge real de não-lidas. -->
	<a
		href="/notificacoes"
		title="Notificações"
		aria-label={unread > 0 ? `Notificações (${unread} não lidas)` : 'Notificações'}
		aria-current={notificacoesActive ? 'page' : undefined}
		class="relative grid size-10 place-items-center rounded-lg transition-colors {notificacoesActive
			? 'bg-rail-item text-white'
			: 'text-white/60 hover:bg-rail-item/60 hover:text-white'}"
	>
		<Bell size={18} />
		{#if unread > 0}
			<span
				class="absolute -right-0.5 -top-0.5 grid h-3.75 min-w-3.75 place-items-center rounded-full border-[1.5px] border-rail bg-accent px-0.75 text-[9px] font-semibold leading-none text-on-solid"
			>
				{badge}
			</span>
		{/if}
	</a>

	<!-- Tema: no rodapé do rail (o avatar do usuário mora no topbar). -->
	<ThemeToggle initial={theme} variant="rail" />
</nav>
