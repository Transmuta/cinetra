<script lang="ts">
	// Agenda (doc 25 §6). No protótipo `sbAgenda()` é o ramo `default:` de `sidebarBody` [:1407];
	// aqui é um ramo EXPLÍCITO por decisão — um default silencioso faria toda seção futura herdar
	// a sidebar da agenda sem querer.
	//
	// O filtro por profissional é o ÚNICO da agenda e viaja em `?profs=` — a lista dos OCULTOS,
	// para que a URL normal fique limpa. Tudo por `<a>`: o estado mora na URL.
	import { page } from '$app/state';
	import Check from '@lucide/svelte/icons/check';
	import { avatarColor, avatarStyle } from '$lib/avatar';
	import type { Professional } from '$lib/professionals';

	const dados = $derived(
		page.data as { professionals?: Professional[]; hidden?: string[]; date?: string }
	);

	const agendaProfs = $derived(dados.professionals ?? []);
	const agendaHidden = $derived(dados.hidden ?? []);
	const agendaDate = $derived(dados.date ?? '');

	// A query é montada à mão, e não com `URLSearchParams`, por um motivo só: ele escaparia a
	// vírgula de `profs=p1,p2` para `%2C`. A vírgula é legal num valor de query (RFC 3986) e a URL
	// da agenda é para ser lida e colada por gente.
	function agendaHref(hidden: string[]): string {
		const partes: string[] = [];
		if (agendaDate) partes.push(`date=${agendaDate}`);
		if (hidden.length) partes.push(`profs=${hidden.map(encodeURIComponent).join(',')}`);
		return partes.length ? `/agenda?${partes.join('&')}` : '/agenda';
	}

	// O link de cada linha leva ao estado RESULTANTE do clique: ocultar quem está visível, revelar
	// quem está oculto.
	const toggleHref = (id: string) =>
		agendaHref(
			agendaHidden.includes(id) ? agendaHidden.filter((x) => x !== id) : [...agendaHidden, id]
		);
</script>

	<div class="flex-1 overflow-auto px-3 py-1">
		<div
			class="flex items-center justify-between px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint"
		>
			<span>Profissionais</span>
			{#if agendaHidden.length}
				<a href={agendaHref([])} class="normal-case tracking-normal text-accent-text hover:underline">
					Mostrar todos
				</a>
			{/if}
		</div>

		{#if agendaProfs.length}
			{#each agendaProfs as prof (prof.id)}
				{@const oculto = agendaHidden.includes(prof.id)}
				<a
					href={toggleHref(prof.id)}
					aria-label="{oculto ? 'Mostrar' : 'Ocultar'} {prof.nome}"
					class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo hover:bg-surface-2 {oculto
						? 'text-faint'
						: 'font-medium text-ink'}"
				>
					<!-- O ✓ herda `currentColor`, então quem decide a cor dele é o `avatarStyle`: branco
					     cravado desaparecia sobre as cores claras da paleta (o âmbar dava 2,25:1). -->
					<span
						class="grid size-4 shrink-0 place-items-center rounded-micro border {oculto
							? 'border-edge-strong'
							: 'border-transparent'}"
						style={oculto ? '' : avatarStyle(prof.cor_indice)}
					>
						{#if !oculto}<Check size={11} />{/if}
					</span>
					<span class="flex-1 truncate">{prof.nome}</span>
				</a>
			{/each}
		{:else}
			<div class="px-2.5 py-2 text-rotulo text-faint">Nenhum profissional cadastrado.</div>
		{/if}
	</div>