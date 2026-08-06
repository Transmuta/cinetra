<script lang="ts">
	import Menu from '@lucide/svelte/icons/menu';
	import UserMenu from './UserMenu.svelte';
	import { sectionOf, SECTION_TITLES } from './nav';
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

	<UserMenu {me} placement="topbar" />
</header>
