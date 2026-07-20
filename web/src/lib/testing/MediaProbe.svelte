<script lang="ts">
	// Sonda de teste para `$lib/media.svelte`: o hook usa `onDestroy`, que exige contexto de
	// componente — então ele só é exercitável de dentro de um. Fica em `testing/` (fora da
	// cobertura, como as fábricas de fixture) por ser andaime, não superfície de produção.
	import { mediaQuery } from '$lib/media.svelte';

	let { query }: { query: string } = $props();

	// A query é fixa por construção (é uma constante do módulo, não estado de tela): ler uma
	// vez na montagem é o contrato do hook, não um descuido de reatividade.
	// svelte-ignore state_referenced_locally
	const m = mediaQuery(query);
</script>

<span data-testid="matches">{m.current ? 'sim' : 'não'}</span>
