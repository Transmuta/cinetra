<script lang="ts">
	import AuthCard from '$lib/components/AuthCard.svelte';
	import AuthForm from '$lib/components/AuthForm.svelte';
	import type { PageData, ActionData } from './$types';

	import Seo from '$lib/components/Seo.svelte';

	let { data, form }: { data: PageData; form: ActionData } = $props();
</script>

<Seo
	titulo="Entrar · Cinetra"
	descricao="Acesse a agenda da sua clínica na Cinetra. Entrada por link mágico no e-mail ou pela conta Google, sem senha para lembrar."
	canonical={data.canonical}
	origem={data.origem}
/>

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
