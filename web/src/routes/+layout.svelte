<script lang="ts">
	// Fontes self-hosted (sem requisição externa): Hanken Grotesk (UI) + Martian Mono (números).
	import '@fontsource-variable/hanken-grotesk';
	import '@fontsource/martian-mono/400.css';
	import '@fontsource/martian-mono/500.css';
	import '@fontsource/martian-mono/600.css';
	// Design system (ADR-010): tokens + tema + base.
	import '$lib/styles/app.css';
	import favicon from '$lib/assets/favicon.svg';
	// A fatia latina da Hanken — a única que texto em pt-BR pede. `?url` devolve a MESMA URL
	// com hash que o @font-face do Fontsource usa (o Vite deduplica o asset), então o preload
	// aquece exatamente o arquivo que o CSS vai pedir. Ver o <link> abaixo.
	import hankenLatin from '@fontsource-variable/hanken-grotesk/files/hanken-grotesk-latin-wght-normal.woff2?url';

	let { children } = $props();
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<!-- Preload da fonte de texto (doc 57). O @font-face só é descoberto depois que o CSS baixa
	     E o layout casa um nó de texto com a família — tarde demais: a página pintava na fonte
	     de sistema e trocava depois, e essa troca era 100% do CLS de 0,177 medido na landing
	     (a manchete do herói remonta e empurra a página inteira). Com o preload o arquivo entra
	     no ar junto com o CSS e o primeiro paint já sai na fonte certa.
	     `crossorigin` é OBRIGATÓRIO mesmo em mesma origem: fonte é sempre buscada em modo CORS,
	     e sem o atributo o browser baixa duas vezes (o preload não casa com o pedido do CSS). -->
	<link rel="preload" href={hankenLatin} as="font" type="font/woff2" crossorigin="anonymous" />
</svelte:head>

{@render children()}
