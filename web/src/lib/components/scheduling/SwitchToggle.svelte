<script lang="ts">
	// Toggle deslizante fiel ao `switchToggle` do protótipo (:2360): substitui o checkbox
	// "Aberto/Fechado". Controlado — emite `onchange` no clique; quem chama vira o estado.
	let {
		checked,
		disabled = false,
		label,
		onchange
	}: {
		checked: boolean;
		disabled?: boolean;
		label?: string;
		onchange: () => void;
	} = $props();
</script>

<button
	type="button"
	role="switch"
	aria-checked={checked}
	aria-label={label}
	{disabled}
	onclick={() => !disabled && onchange()}
	class="relative h-[22px] w-[38px] shrink-0 rounded-full transition-colors disabled:cursor-not-allowed disabled:opacity-50 {checked
		? 'bg-accent'
		: 'bg-edge'}"
>
	<span
		class="absolute top-[3px] size-4 rounded-full bg-white shadow-sm transition-all {checked
			? 'left-[19px]'
			: 'left-[3px]'}"
	></span>
</button>
