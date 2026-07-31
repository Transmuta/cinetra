<script lang="ts">
	// O checkbox "Encaixe" do formulário — compartilhado por criar e remarcar (Entrega 4).
	// `name="encaixe"` porque o valor viaja no form da action; renderiza inline dentro do
	// `<form>` do pai. Some inteiro para quem não pode marcar encaixe (A9 / D2).
	let {
		checked = $bindable(false),
		podeEncaixe
	}: {
		checked?: boolean;
		podeEncaixe: boolean;
	} = $props();
</script>

{#if podeEncaixe}
	<label class="flex cursor-pointer items-center gap-2 py-1 text-[13px]">
		<input type="checkbox" name="encaixe" bind:checked class="size-4 accent-primary" />
		Encaixe
		<span class="text-[12px] text-faint">(ignora conflito de horário)</span>
	</label>
{/if}
