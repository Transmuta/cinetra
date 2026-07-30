<script lang="ts">
	// Topo das páginas públicas (landing e documentos legais). Saiu de dentro do `+page.svelte`
	// da landing quando as páginas legais passaram a precisar do MESMO topo: duas cópias de uma
	// barra de navegação divergem no dia em que alguém acrescenta um item em uma só.
	import Logo from '../Logo.svelte';

	// A landing usa âncora pura (`#precos`, rolagem na própria página); as outras páginas
	// públicas precisam voltar para a home antes de rolar (`/#precos`), senão o link não faz nada.
	let { prefixo = '' }: { prefixo?: string } = $props();

	const secoes = [
		{ href: '#dores', label: 'As dores' },
		{ href: '#recursos', label: 'Recursos' },
		{ href: '#precos', label: 'Planos' },
		{ href: '#duvidas', label: 'Dúvidas' }
	];
</script>

<header style="position:sticky;top:0;z-index:60;background:#F6F4EF;border-bottom:1px solid #E6E2D8">
	<div
		class="cn-topbar"
		style="max-width:1160px;margin:0 auto;padding:13px 30px;display:flex;align-items:center;gap:34px"
	>
		<a href="/" aria-label="Cinetra, página inicial" style="display:flex;align-items:center"
			><Logo class="h-5.75 w-auto" /></a
		>
		<nav
			class="cn-navlinks"
			aria-label="Seções da página"
			style="display:flex;gap:26px;margin-left:8px;font-size:14.5px;font-weight:500;color:#5A5448"
		>
			{#each secoes as secao (secao.href)}
				<a href="{prefixo}{secao.href}" style="transition:color .2s">{secao.label}</a>
			{/each}
		</nav>
		<div style="margin-left:auto;display:flex;align-items:center;gap:6px">
			<a
				href="/entrar"
				class="cn-hover-nav"
				style="color:#212A37;font-size:14.5px;font-weight:600;padding:8px 14px;border-radius:9px"
				>Entrar</a
			>
			<a
				href="/criar-conta"
				class="cn-hover-dark"
				style="background:#212A37;color:#fff;font-size:14.5px;font-weight:600;padding:9px 16px;border-radius:9px"
				>Começar grátis</a
			>
		</div>
	</div>
</header>
