<script lang="ts">
	// Rodapé das páginas públicas (landing e documentos legais), extraído junto com o `SiteHeader`.
	import Logo from '../Logo.svelte';
	import { DOCUMENTOS } from '$lib/legal';

	// Sempre com `/` na frente, ao contrário do topo: o rodapé aparece TAMBÉM nas páginas legais,
	// onde não existe seção de planos para a âncora encontrar.
	const secoes = [
		{ href: '/#recursos', label: 'Recursos' },
		{ href: '/#precos', label: 'Planos' },
		{ href: '/#duvidas', label: 'Dúvidas' },
		{ href: '/entrar', label: 'Entrar' }
	];
</script>

<footer class="cn-foot" style="border-top:1px solid #E6E2D8;padding:44px 0;background:#F6F4EF">
	<div
		class="cn-footrow"
		style="max-width:1160px;margin:0 auto;padding:0 30px;display:flex;flex-wrap:wrap;gap:24px;align-items:center;justify-content:space-between"
	>
		<Logo class="h-6.5 w-auto" />
		<nav
			aria-label="Rodapé"
			style="display:flex;gap:24px;font-size:14px;color:#696356;flex-wrap:wrap"
		>
			{#each secoes as secao (secao.href)}
				<a href={secao.href} style="transition:color .2s">{secao.label}</a>
			{/each}
			<!-- Os documentos legais só são alcançáveis por aqui: é o único ponto de entrada fixo
			     em todas as páginas públicas. -->
			{#each DOCUMENTOS as doc (doc.caminho)}
				<a href={doc.caminho} style="transition:color .2s">{doc.titulo}</a>
			{/each}
		</nav>
		<div style="font-size:13px;color:#696356">
			© 2026 Cinetra · Feito para clínicas de fisioterapia
		</div>
	</div>
</footer>
