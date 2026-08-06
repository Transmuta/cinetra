<script lang="ts">
	import Menu from '@lucide/svelte/icons/menu';
	import CircleHelp from '@lucide/svelte/icons/circle-help';
	import UserMenu from './UserMenu.svelte';
	import { sectionOf, SECTION_TITLES } from './nav';
	import { ajudaDaRota } from '$lib/ajuda';
	import type { Me } from '$lib/session';

	// Faixa do acento, 2px + título à esquerda; à direita, o avatar do usuário (menu). No mobile,
	// um hambúrguer à esquerda abre o rail+sidebar como gaveta (onMenu, tratado no layout).
	let {
		pathname,
		me,
		onMenu,
		menuAberto = false
	}: {
		pathname: string;
		me: Me;
		onMenu?: () => void;
		/**
		 * A gaveta está aberta? (ACC-08) Serve ao `aria-expanded`: sem ele o hambúrguer é um botão
		 * sem estado, e quem usa leitor de tela não sabe se abriu. Quem guarda o estado é o layout,
		 * que também é quem fecha a gaveta ao navegar.
		 */
		menuAberto?: boolean;
	} = $props();

	const section = $derived(sectionOf(pathname));
	const title = $derived(section ? SECTION_TITLES[section] : 'Cinetra');

	// A ajuda DESTA tela (doc 108 §6). O "?" genérico levaria ao índice e faria a pessoa procurar
	// de novo o que ela já está olhando; quando a rota tem tópico, ele abre o tópico.
	const ajuda = $derived(ajudaDaRota(pathname));
</script>

<div class="h-0.5 shrink-0 bg-accent"></div>
<header class="flex h-14 shrink-0 items-center gap-3 border-b border-edge bg-surface px-4 sm:px-5">
	<button
		type="button"
		onclick={onMenu}
		aria-label={menuAberto ? 'Fechar menu' : 'Abrir menu'}
		aria-expanded={menuAberto}
		aria-controls="menu-navegacao"
		class="grid size-9 shrink-0 place-items-center rounded-controle text-muted hover:bg-surface-2 lg:hidden"
	>
		<Menu size={20} />
	</button>

	<h1 class="min-w-0 flex-1 truncate text-titulo font-bold">{title}</h1>

	<!-- `target="_blank"`: a ajuda é consultada NO MEIO de uma tarefa — com um formulário meio
	     preenchido atrás. Navegar na mesma aba jogaria fora o que a pessoa estava digitando, que é
	     exatamente o momento em que ela foi procurar ajuda. -->
	<a
		href={ajuda ? `/ajuda/${ajuda.id}` : '/ajuda'}
		target="_blank"
		rel="noopener"
		title={ajuda ? `Ajuda: ${ajuda.titulo}` : 'Central de ajuda'}
		aria-label={ajuda ? `Ajuda: ${ajuda.titulo}` : 'Central de ajuda'}
		class="grid size-9 shrink-0 place-items-center rounded-controle text-muted hover:bg-surface-2 hover:text-ink"
	>
		<CircleHelp size={18} />
	</a>

	<UserMenu {me} placement="topbar" />
</header>
