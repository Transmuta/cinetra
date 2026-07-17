<script lang="ts">
	import AuthCard from '$lib/components/AuthCard.svelte';
	import AuthForm from '$lib/components/AuthForm.svelte';
	import type { PageData, ActionData } from './$types';

	let { form }: { data: PageData; form: ActionData } = $props();
</script>

<svelte:head><title>Entrar · Cinetra</title></svelte:head>

<AuthCard
	title="Bem-vindo de volta"
	subtitle="Entre para acessar a agenda da sua clínica."
>
	<AuthForm {form} submitLabel="Enviar link de acesso" googleLabel="Continuar com Google" />

	{#snippet footer()}
		Não tem conta?
		<a href="/criar-conta" style="font-weight:600;color:#4E7468">Criar conta</a>
	{/snippet}
</AuthCard>
