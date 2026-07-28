<script lang="ts">
	// As tags de `<head>` das páginas públicas (doc 57).
	//
	// Existe porque são TRÊS páginas (`/`, `/entrar`, `/criar-conta`) e ~15 tags cada. Copiadas,
	// divergem calado: a que some é a que ninguém vê faltar, porque nada quebra — só o card do
	// WhatsApp fica sem imagem e a canônica aponta para outro lugar.
	//
	// `<svelte:head>` dentro de componente funciona: o SvelteKit iça o conteúdo para o `<head>`
	// do documento no SSR. O JSON-LD NÃO mora aqui — é específico da landing, e enfiá-lo neste
	// componente obrigaria a passar um objeto que só uma das três páginas usa.
	import { SITE } from '$lib/seo';

	let {
		titulo,
		descricao,
		canonical,
		origem,
		// Em card de rede social vende-se a promessa, não a palavra-chave: quem clicou já veio
		// pelo link, não por uma consulta. A landing passa a manchete aqui; as outras duas não
		// têm manchete própria e caem no título mesmo.
		ogTitulo = titulo
	}: {
		titulo: string;
		descricao: string;
		canonical: string;
		origem: string;
		ogTitulo?: string;
	} = $props();

	// `$derived`, não `const`: `origem` é prop, e um `const` capturaria só o valor inicial — o
	// card ficaria com a origem da primeira página renderizada depois de uma navegação no client.
	const imagem = $derived(`${origem}/og.png`);
</script>

<svelte:head>
	<title>{titulo}</title>
	<meta name="description" content={descricao} />

	<!-- As três chegam com query (`?utm_…` de campanha, `?erro=…` do magic link) e sem esta
	     linha cada variante vira uma URL concorrente da mesma página no índice. -->
	<link rel="canonical" href={canonical} />

	<!-- Navy da marca na barra do browser: as três páginas públicas usam a paleta quente, então
	     nenhuma delas quer abrir com uma faixa branca em cima. -->
	<meta name="theme-color" content="#212A37" />

	<meta property="og:type" content="website" />
	<meta property="og:site_name" content={SITE.nome} />
	<meta property="og:locale" content={SITE.locale} />
	<meta property="og:url" content={canonical} />
	<meta property="og:title" content={ogTitulo} />
	<meta property="og:description" content={descricao} />
	<meta property="og:image" content={imagem} />
	<meta property="og:image:width" content="1200" />
	<meta property="og:image:height" content="630" />
	<meta property="og:image:alt" content="Cinetra: agenda e gestão para clínicas de fisioterapia" />

	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content={ogTitulo} />
	<meta name="twitter:description" content={descricao} />
	<meta name="twitter:image" content={imagem} />
</svelte:head>
