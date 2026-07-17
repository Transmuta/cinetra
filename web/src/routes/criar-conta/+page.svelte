<script lang="ts">
	import AuthCard from '$lib/components/AuthCard.svelte';
	import AuthForm from '$lib/components/AuthForm.svelte';
	import type { PageData, ActionData } from './$types';

	let { form }: { data: PageData; form: ActionData } = $props();
</script>

<svelte:head><title>Criar conta · Cinetra</title></svelte:head>

<AuthCard title="Criar sua conta" subtitle="14 dias grátis. Sem cartão de crédito.">
	<AuthForm {form} collectName submitLabel="Criar conta grátis" googleLabel="Continuar com Google" />

	{#snippet footer()}
		Já tem conta?
		<a href="/entrar" style="font-weight:600;color:#4E7468">Entrar</a>
	{/snippet}
</AuthCard>
