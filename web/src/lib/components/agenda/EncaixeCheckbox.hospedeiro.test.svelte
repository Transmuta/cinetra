<script lang="ts">
	// Hospedeiro do teste: o componente rende INLINE dentro do `<form>` do pai, e o que precisa
	// ser provado é justamente o que sai no `FormData` desse form. `render(Componente, props)`
	// não tem form nenhum em volta, então o valor não teria como ser lido.
	import EncaixeCheckbox from './EncaixeCheckbox.svelte';

	let { podeEncaixe = true, checked = $bindable(false) } = $props();
</script>

<form data-testid="form">
	<EncaixeCheckbox bind:checked {podeEncaixe} />
</form>
