<script lang="ts">
	// Pacientes: "Novo paciente" + FILTRAR. Eixo único (como o `pacFiltro` do protótipo :1437):
	// status + os segmentos calculáveis hoje (com responsável). Viaja por `?filter=`.
	import { page } from '$app/state';
	import UserPlus from '@lucide/svelte/icons/user-plus';
	import Plus from '@lucide/svelte/icons/plus';
	import Users from '@lucide/svelte/icons/users';
	import UserCheck from '@lucide/svelte/icons/user-check';
	import UserX from '@lucide/svelte/icons/user-x';
	import UserCog from '@lucide/svelte/icons/user-cog';
	import { canManagePatients, type PatientCounts } from '$lib/patients';
	import type { Papel } from '$lib/session';

	// `counts` aqui é `PatientCounts`. Na fila, a MESMA chave é `WaitlistCounts` — enquanto os
	// oito ramos moravam num arquivo só, o TypeScript não podia ajudar e o cast era a única saída
	// (doc 94 §3.5). Um arquivo por seção resolve o contrato, não só o transporte.
	const dados = $derived(page.data as { counts?: PatientCounts; me?: { papel?: Papel | null } });

	const PAT_FILTERS = [
		{ key: 'todos', label: 'Todos os pacientes', icon: Users },
		{ key: 'ativos', label: 'Ativos', icon: UserCheck },
		{ key: 'inativos', label: 'Inativos', icon: UserX },
		{ key: 'resp', label: 'Com responsável', icon: UserCog }
	] as const;

	// As contagens vêm do servidor: a lista é paginada, então contar o que chegou contaria só a
	// página.
	const patCounts = $derived(dados.counts ?? { todos: 0, ativos: 0, inativos: 0, resp: 0 });
	// F3 (doc 34): só a lista traz `counts`. Sem eles, esconder em vez de mostrar 0.
	const hasPatCounts = $derived(dados.counts !== undefined);
	const canManagePat = $derived(canManagePatients(dados.me?.papel));
	const patFilter = $derived(page.url.searchParams.get('filter') ?? 'todos');
</script>

	<div class="flex-1 overflow-auto px-3 py-1">
		{#if canManagePat}
			<a
				href="/pacientes/novo"
				class="mb-2 flex items-center justify-center gap-1.5 rounded-controle bg-ink px-3 py-2.5 text-corpo font-semibold text-canvas hover:opacity-90"
			>
				<UserPlus size={15} /> Novo paciente
			</a>
		{/if}

		<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
			Segmentos
		</div>
		{#each PAT_FILTERS as fil (fil.key)}
			{@const isActive = patFilter === fil.key}
			<a
				href="/pacientes?filter={fil.key}"
				aria-current={isActive ? 'page' : undefined}
				class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo {isActive
					? 'bg-surface-2 font-semibold text-ink'
					: 'font-medium text-muted hover:bg-surface-2'}"
			>
				<span class={isActive ? 'text-accent-text' : 'text-faint'}><fil.icon size={15} /></span>
				<span class="flex-1 truncate">{fil.label}</span>
				{#if hasPatCounts}
					<span class="font-mono text-meta text-faint">{patCounts[fil.key]}</span>
				{/if}
			</a>
		{/each}
	</div>