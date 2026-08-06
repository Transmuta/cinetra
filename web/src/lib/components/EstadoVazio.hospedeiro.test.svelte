<script lang="ts">
	// Hospedeiro do teste: os snippets `descricao` e `acao` só existem em marcação, então não dá
	// para passá-los pelo `render(Componente, props)`.
	import SearchX from '@lucide/svelte/icons/search-x';
	import EstadoVazio from './EstadoVazio.svelte';
</script>

<EstadoVazio icone={SearchX} titulo="Nenhuma alteração com esses filtros">
	{#snippet descricao()}
		Tente ampliar o período.
	{/snippet}
	{#snippet acao()}
		<button type="button">Limpar filtros</button>
	{/snippet}
</EstadoVazio>
