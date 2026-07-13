<script lang="ts">
	import { page } from '$app/state';
	import Logo from '$lib/components/Logo.svelte';
</script>

<svelte:head><title>{page.status} · Movimento</title></svelte:head>

<main class="grid min-h-dvh place-items-center bg-canvas px-6 text-ink">
	<div class="text-center">
		<div class="mb-6 flex justify-center"><Logo /></div>
		<div class="font-mono text-[15px] font-semibold text-faint">{page.status}</div>
		<h1 class="mt-1 text-[20px] font-bold">
			{page.status === 404 ? 'Página não encontrada' : 'Algo deu errado'}
		</h1>
		<p class="mt-1 text-[13px] text-muted">{page.error?.message ?? 'Tente novamente em instantes.'}</p>
		<a
			href="/"
			class="mt-5 inline-block text-[13px] font-semibold text-teal-text hover:underline"
		>
			Voltar ao início
		</a>
	</div>
</main>
