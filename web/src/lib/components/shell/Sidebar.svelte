<script lang="ts">
	// A barra contextual: identidade da clínica no topo, título da seção, e o painel daquela seção.
	//
	// Eram **596 linhas com sete barras laterais num arquivo só** (doc 94 §4.1), e o acoplamento
	// aparecia no tipo: este componente lia 20 chaves de `page.data`, cada uma com um cast, porque
	// era o único ponto do app que conhecia o `data` de sete rotas ao mesmo tempo. A chave `counts`
	// chegava a ser lida como DOIS tipos diferentes conforme a rota (doc 94 §3.5).
	//
	// Agora cada seção é um arquivo, e cada arquivo declara o `page.data` que ELE consome — um
	// `as` na fronteira em vez de 20 espalhados. O que sobra aqui é o cromo e a decisão de qual
	// montar.
	import MapPin from '@lucide/svelte/icons/map-pin';
	import { maskCnpj } from '$lib/cnpj';
	import { sectionOf, SECTION_TITLES } from './nav';
	import SidebarConfig from './sidebar/SidebarConfig.svelte';
	import SidebarProfissionais from './sidebar/SidebarProfissionais.svelte';
	import SidebarAgenda from './sidebar/SidebarAgenda.svelte';
	import SidebarPacientes from './sidebar/SidebarPacientes.svelte';
	import SidebarFila from './sidebar/SidebarFila.svelte';
	import SidebarNotificacoes from './sidebar/SidebarNotificacoes.svelte';
	import SidebarAuditoria from './sidebar/SidebarAuditoria.svelte';
	import SidebarRelatorios from './sidebar/SidebarRelatorios.svelte';

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
</script>

<!-- ACC-24 (doc 83): o `aside` é um landmark `complementary`, e sem rótulo ele é anunciado como
     "complementar" e nada mais — havia dois landmarks de navegação na tela, um deles anônimo. O
     rótulo acompanha a seção, que é o que este painel de fato contextualiza. -->
<aside
	aria-label={title ? `Painel de ${title}` : 'Painel da seção'}
	class="flex w-64 shrink-0 flex-col border-r border-edge bg-surface"
>
	<!-- Topo: identidade da clínica (o símbolo Cinetra vive no rail). Quando há nome, ele ocupa
	     o lugar da marca; CNPJ e endereço entram como subtítulo. Sem nome (borda), cai na marca. -->
	<div class="px-4 pb-1 pt-4">
		{#if clinicName}
			<div class="text-titulo font-extrabold leading-tight tracking-tight">{clinicName}</div>
			{#if clinicCnpj}
				<div class="mt-1 font-mono text-meta text-faint">{maskCnpj(clinicCnpj)}</div>
			{/if}
			{#if clinicEndereco}
				<div class="mt-0.5 flex items-start gap-1.5 text-rotulo text-faint">
					<MapPin size={11} class="mt-0.75 shrink-0" />
					<span>{clinicEndereco}</span>
				</div>
			{/if}
		{:else}
			<span class="text-titulo font-extrabold tracking-tight">Cinetra</span>
		{/if}
	</div>

	{#if title}
		<div class="flex items-center gap-1.5 px-4 pb-2 pt-2.5">
			<span class="text-meta font-bold uppercase tracking-[.06em] text-ink">{title}</span>
			<span class="size-[5px] rounded-full bg-accent"></span>
		</div>
	{/if}
	{#if section === 'config'}
		<SidebarConfig {pathname} />
	{:else if section === 'profissionais'}
		<SidebarProfissionais />
	{:else if section === 'agenda'}
		<SidebarAgenda />
	{:else if section === 'pacientes'}
		<SidebarPacientes />
	{:else if section === 'fila'}
		<SidebarFila />
	{:else if section === 'notificacoes'}
		<SidebarNotificacoes />
	{:else if section === 'auditoria'}
		<SidebarAuditoria />
	{:else if section === 'relatorios'}
		<SidebarRelatorios />
	{/if}
</aside>
