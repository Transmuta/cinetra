<script lang="ts">
	import { page } from '$app/state';
	import Construction from '@lucide/svelte/icons/construction';

	const notFound = $derived(page.status === 404);
</script>

<svelte:head><title>{page.status} · Movimento</title></svelte:head>

<div class="grid h-full place-items-center p-8 text-center">
	<div>
		<div class="mx-auto mb-3 grid size-12 place-items-center rounded-xl bg-surface-2 text-faint">
			<Construction size={24} />
		</div>
		<div class="font-mono text-[15px] font-semibold text-faint">{page.status}</div>
		<h1 class="mt-1 text-[18px] font-bold">{notFound ? 'Em construção' : 'Algo deu errado'}</h1>
		<p class="mx-auto mt-1 max-w-[320px] text-[13px] text-muted">
			{notFound
				? 'Esta parte do sistema ainda não foi construída. Volte para a Equipe & acessos.'
				: (page.error?.message ?? 'Tente novamente em instantes.')}
		</p>
		<a
			href="/configuracoes/equipe"
			class="mt-4 inline-block text-[13px] font-semibold text-teal-text hover:underline"
		>
			Ir para Equipe & acessos
		</a>
	</div>
</div>
