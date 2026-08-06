<script lang="ts">
	// Profissionais (profs.png): "Novo profissional" + FILTRAR com contagens. O filtro viaja por
	// `?status=` (a lista o lê da URL).
	import { page } from '$app/state';
	import Plus from '@lucide/svelte/icons/plus';
	import Users from '@lucide/svelte/icons/users';
	import UserCheck from '@lucide/svelte/icons/user-check';
	import UserX from '@lucide/svelte/icons/user-x';
	import { canManageProfessionals, countByStatus, type Professional } from '$lib/professionals';
	import type { Papel } from '$lib/session';

	// O `page.data` da rota, tipado UMA vez, na fronteira. Era o preço de este ramo morar junto
	// dos outros sete: 20 leituras com cast espalhadas, e a chave `counts` lida como DOIS tipos
	// diferentes conforme a seção (doc 94 §3.5).
	const dados = $derived(
		page.data as { professionals?: Professional[]; me?: { papel?: Papel | null } }
	);

	const PROF_FILTERS = [
		{ key: 'todos', label: 'Todos', icon: Users },
		{ key: 'ativos', label: 'Ativos', icon: UserCheck },
		{ key: 'inativos', label: 'Inativos', icon: UserX }
	] as const;

	const profs = $derived(dados.professionals ?? []);
	const profCounts = $derived(countByStatus(profs));
	// F3 (doc 34): a lista carrega os profissionais; telas de detalhe/novo, não. Sem a lista, o
	// número seria um "0" mentiroso (há profissionais) — então escondemos a contagem, não zeramos.
	const hasProfCounts = $derived(dados.professionals !== undefined);
	const canManageProf = $derived(canManageProfessionals(dados.me?.papel));
	const profStatus = $derived(page.url.searchParams.get('status') ?? 'todos');
</script>

	<div class="flex-1 overflow-auto px-3 py-1">
		{#if canManageProf}
			<a
				href="/profissionais/novo"
				class="mb-2 flex items-center justify-center gap-1.5 rounded-controle bg-ink px-3 py-2.5 text-corpo font-semibold text-canvas hover:opacity-90"
			>
				<Plus size={15} /> Novo profissional
			</a>
		{/if}

		<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
			Filtrar
		</div>
		{#each PROF_FILTERS as fil (fil.key)}
			{@const isActive = profStatus === fil.key}
			<a
				href="/profissionais?status={fil.key}"
				aria-current={isActive ? 'page' : undefined}
				class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo {isActive
					? 'bg-surface-2 font-semibold text-ink'
					: 'font-medium text-muted hover:bg-surface-2'}"
			>
				<span class={isActive ? 'text-accent-text' : 'text-faint'}><fil.icon size={15} /></span>
				<span class="flex-1 truncate">{fil.label}</span>
				{#if hasProfCounts}
					<span class="font-mono text-meta text-faint">{profCounts[fil.key]}</span>
				{/if}
			</a>
		{/each}
	</div>