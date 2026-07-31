<script lang="ts">
	import { page } from '$app/state';
	import Construction from '@lucide/svelte/icons/construction';

	const notFound = $derived(page.status === 404);
</script>

<svelte:head><title>{page.status} · Cinetra</title></svelte:head>

<div class="grid h-full place-items-center p-8 text-center">
	<div>
		<div class="mx-auto mb-3 grid size-12 place-items-center rounded-xl bg-surface-2 text-faint">
			<Construction size={24} />
		</div>
		<div class="font-mono text-[15px] font-semibold text-faint">{page.status}</div>
		<!--
			O texto era "Em construção … volte para a Equipe & acessos" — herança da fatia em que
			`/configuracoes/equipe` era a única tela pronta (doc 88, A-7). Duas coisas erradas hoje:
			quem digitou a URL torta lia que a funcionalidade estava a caminho, e o caminho de volta
			levava à tela de EQUIPE, que nem é a casa de ninguém — e menos ainda de uma recepção, que
			chega aqui vinda do 403 da Auditoria.
		-->
		<h1 class="mt-1 text-[18px] font-bold">
			{notFound ? 'Página não encontrada' : 'Algo deu errado'}
		</h1>
		<p class="mx-auto mt-1 max-w-[320px] text-[13px] text-muted">
			{notFound
				? 'Este endereço não existe. Confira o link ou volte para a agenda.'
				: (page.error?.message ?? 'Tente novamente em instantes.')}
		</p>
		<a
			href="/agenda"
			class="mt-4 inline-block text-[13px] font-semibold text-accent-text hover:underline"
		>
			Ir para a agenda
		</a>
	</div>
</div>
