<script lang="ts">
	import { page } from '$app/state';
	import Search from '@lucide/svelte/icons/search';
	import Plus from '@lucide/svelte/icons/plus';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import Phone from '@lucide/svelte/icons/phone';
	import { initials } from '$lib/format';
	import { avatarStyle } from '$lib/avatar';
	import { formatarTelefone } from '$lib/telefone';
	import {
		canManageProfessionals,
		profColor,
		filterByStatus,
		searchProfessionals,
		attendanceSummary,
		especialidadeLabel,
		CONTRACT_LABELS,
		type Professional,
		type StatusFilter
	} from '$lib/professionals';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	// Gestão = owner/admin (some o "+" mobile para os demais; a sidebar já faz o mesmo).
	const canManage = $derived(canManageProfessionals(data.me.papel));

	// O filtro por status vem da sidebar contextual (?status=…); default "todos".
	const status = $derived<StatusFilter>(
		(['todos', 'ativos', 'inativos'] as const).find((s) => s === page.url.searchParams.get('status')) ??
			'todos'
	);

	let term = $state('');
	const visible = $derived(searchProfessionals(filterByStatus(data.professionals, status), term));

	// A linha inteira clica para editar; arquivar/reativar mora na ficha (protótipo :2945).
	function attendance(p: Professional) {
		return attendanceSummary(p, data.clinicHours);
	}

	const COLS = 'md:grid-cols-[2.05fr_1.35fr_1.15fr_0.9fr_1.25fr]';
	const pill =
		'inline-block rounded-full bg-accent-subtle px-2 py-0.5 text-[10.5px] font-semibold text-accent-text';
</script>

<svelte:head><title>Profissionais · Cinetra</title></svelte:head>

<div class="px-4 py-4 md:px-[18px]">
	<!-- Toolbar: busca + "+" mobile (o "Novo profissional" cheio e o filtro moram na sidebar,
	     que no mobile fica na gaveta — daí o atalho de ícone aqui). -->
	<div class="mb-3.5 flex items-center gap-2">
		<div class="relative max-w-[380px] flex-1">
			<Search size={15} class="absolute top-1/2 left-2.5 -translate-y-1/2 text-faint" />
			<input
				bind:value={term}
				placeholder="Buscar profissional"
				aria-label="Buscar profissional"
				class="h-9 w-full rounded-lg border border-edge bg-surface pr-3 pl-8 text-[13px] text-ink"
			/>
		</div>
		{#if canManage}
			<a
				href="/profissionais/novo"
				title="Novo profissional"
				aria-label="Novo profissional"
				class="grid size-9 shrink-0 place-items-center rounded-lg bg-ink text-canvas hover:opacity-90 md:hidden"
			>
				<Plus size={18} />
			</a>
		{/if}
	</div>

	<div class="overflow-hidden rounded-[10px] border border-edge bg-surface">
		<!-- Cabeçalho (desktop) -->
		<div
			class="hidden gap-2 border-b border-edge px-3.5 pb-2.5 pt-3 text-[12px] font-medium text-faint md:grid {COLS}"
		>
			<span>Profissional</span><span>Especialidade</span><span>Contato</span><span>Vínculo</span>
			<span>Atendimento</span>
		</div>

		{#each visible as p (p.id)}
			{@const at = attendance(p)}
			<!-- Desktop: linha em grid, clicável -->
			<a
				href="/profissionais/{p.id}"
				class="hidden items-center gap-2 border-b border-edge px-3.5 py-[9px] last:border-b-0 hover:bg-surface-2 md:grid {COLS} {p.ativo
					? ''
					: 'opacity-55'}"
			>
				<span class="flex min-w-0 items-center gap-2.5">
					<span
						class="grid size-7 shrink-0 place-items-center rounded-full text-[10px] font-bold"
						style={avatarStyle(p.cor_indice)}
					>
						{initials(p.nome)}
					</span>
					<span class="min-w-0">
						<span class="block truncate text-[13px] font-semibold">
							{p.nome}{#if !p.ativo}<span class="ml-1 text-[10px] font-medium text-faint">(inativo)</span>{/if}
						</span>
						<span class="block font-mono text-[10px] text-faint">{p.crefito ?? '—'}</span>
					</span>
				</span>
				<span class="truncate text-[12.5px] text-muted">{especialidadeLabel(p)}</span>
				<span class="truncate font-mono text-[11px] text-muted">{formatarTelefone(p.tel) ?? '—'}</span>
				<span>
					{#if p.vinculo}<span class={pill}>{CONTRACT_LABELS[p.vinculo]}</span>{:else}<span
							class="text-[11px] text-faint">—</span
						>{/if}
				</span>
				<span class="min-w-0 text-[12px] text-muted">
					<span class="flex items-center gap-1.5"><CalendarClock size={12} /> {at.days}</span>
					{#if at.hours}
						<span class="block font-mono text-[10.5px] text-faint">{at.hours}</span>
					{:else if at.followsClinic}
						<span class="block text-[10px] font-semibold text-accent-text">Segue a clínica</span>
					{/if}
				</span>
			</a>

			<!-- Mobile: cartão empilhado -->
			<a
				href="/profissionais/{p.id}"
				class="flex flex-col gap-2 border-b border-edge px-3.5 py-3 last:border-b-0 md:hidden {p.ativo
					? ''
					: 'opacity-55'}"
			>
				<div class="flex items-center gap-2.5">
					<span
						class="grid size-8.5 shrink-0 place-items-center rounded-full text-[11px] font-bold"
						style={avatarStyle(p.cor_indice)}
					>
						{initials(p.nome)}
					</span>
					<div class="min-w-0 flex-1">
						<div class="truncate text-[14px] font-semibold">
							{p.nome}{#if !p.ativo}<span class="ml-1 text-[10px] font-medium text-faint">(inativo)</span>{/if}
						</div>
						<div class="font-mono text-[10.5px] text-faint">{p.crefito ?? '—'}</div>
					</div>
					{#if p.vinculo}<span class={pill}>{CONTRACT_LABELS[p.vinculo]}</span>{/if}
				</div>
				<div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-[12px] text-muted">
					<span class="inline-flex items-center gap-1.5"><Stethoscope size={12} /> {especialidadeLabel(p)}</span>
					{#if p.tel}<span class="inline-flex items-center gap-1.5 font-mono"><Phone size={12} /> {formatarTelefone(p.tel)}</span>{/if}
				</div>
				<div class="flex items-center gap-1.5 text-[12px] text-muted">
					<CalendarClock size={12} /> {at.days}
					{#if at.hours}<span class="font-mono text-[11px] text-faint">{at.hours}</span>
					{:else if at.followsClinic}<span class="text-[11px] font-semibold text-accent-text">· Segue a clínica</span>{/if}
				</div>
			</a>
		{/each}

		{#if !visible.length}
			<div class="px-7 py-7 text-center text-[13px] text-faint">
				{#if term}
					Nenhum profissional encontrado para “{term}”.
				{:else if status === 'inativos'}
					Nenhum profissional inativo.
				{:else}
					Nenhum profissional ainda.
				{/if}
			</div>
		{/if}
	</div>
</div>
