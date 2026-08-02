<script lang="ts">
	// O "Encaixe" do formulário — compartilhado por criar, remarcar e oferecer vaga (Entrega 4).
	// Some inteiro para quem não pode marcar encaixe (A9 / D2).
	//
	// Virou `SwitchToggle` junto com os outros booleanos de opção única. Botão não entra no
	// FormData (doc 98 §6), então quem leva o valor à action é o hidden abaixo — e é isso que os
	// testes de FormData deste componente guardam. Sem ele, o encaixe some em silêncio e o
	// sintoma vira um 409 de conflito sem explicação.
	import SwitchToggle from '$lib/components/scheduling/SwitchToggle.svelte';

	let {
		checked = $bindable(false),
		podeEncaixe
	}: {
		checked?: boolean;
		podeEncaixe: boolean;
	} = $props();
</script>

{#if podeEncaixe}
	<div class="flex items-center gap-2 py-1 text-corpo">
		<SwitchToggle {checked} label="Encaixe" onchange={() => (checked = !checked)} />
		<span>Encaixe</span>
		<span class="text-rotulo text-faint">(ignora conflito de horário)</span>
	</div>
	<input type="hidden" name="encaixe" value={checked ? 'on' : ''} />
{/if}
