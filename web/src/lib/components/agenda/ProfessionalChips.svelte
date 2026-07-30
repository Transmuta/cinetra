<script lang="ts">
	// Barra de chips do mobile (protótipo :1714): abaixo de 860px a agenda mostra **um
	// profissional por vez**, e é aqui que se escolhe qual.
	//
	// Divergência do protótipo: o chip mostra o PRIMEIRO nome, não o segundo token
	// (`pr.nome.split(' ')[1]`, :1716) — que quebra em quem tem nome composto, em quem tem
	// nome só, e mostra "Paula" para "Ana Paula Lima".
	import { avatarColor, avatarStyle } from '$lib/avatar';
	import type { AgendaProfessional } from '$lib/agenda';

	let {
		professionals,
		selected,
		onSelect
	}: {
		professionals: AgendaProfessional[];
		selected: string | null;
		onSelect: (id: string) => void;
	} = $props();

	const primeiroNome = (p: AgendaProfessional) => (p.nome_exibicao || p.nome).split(' ')[0];
</script>

<div
	class="sticky top-0 z-6 flex gap-1.5 overflow-x-auto border-b border-edge bg-surface px-2.5 py-2.5"
	role="tablist"
	aria-label="Profissional em exibição"
>
	{#each professionals as prof (prof.id)}
		<button
			type="button"
			role="tab"
			aria-selected={prof.id === selected}
			onclick={() => onSelect(prof.id)}
			class="flex shrink-0 items-center gap-1.5 rounded-full border px-2.5 py-1.5 text-[12.5px] font-semibold {prof.id ===
			selected
				? 'border-transparent bg-primary text-on-primary'
				: 'border-edge bg-surface text-ink'}"
		>
			<span
				class="size-[18px] rounded-full"
				style={avatarStyle(prof.cor_indice)}
				aria-hidden="true"
			></span>
			{primeiroNome(prof)}
		</button>
	{/each}
</div>
