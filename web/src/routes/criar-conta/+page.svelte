<script lang="ts">
	import AuthCard from '$lib/components/AuthCard.svelte';
	import AuthForm from '$lib/components/AuthForm.svelte';
	import type { PageData, ActionData } from './$types';

	import Seo from '$lib/components/Seo.svelte';

	let { data, form }: { data: PageData; form: ActionData } = $props();
</script>

<Seo
	titulo="Criar conta grátis · Cinetra"
	descricao="Teste a Cinetra por 14 dias, sem cartão de crédito. Agenda, pacotes de sessões e confirmação no WhatsApp para a sua clínica de fisioterapia."
	canonical={data.canonical}
	origem={data.origem}
	ogTitulo="14 dias grátis na Cinetra, sem cartão de crédito."
/>

<AuthCard title="Criar sua conta" subtitle="14 dias grátis. Sem cartão de crédito.">
	<AuthForm {form} collectName submitLabel="Criar conta grátis" googleLabel="Continuar com Google" />

	{#snippet footer()}
		Já tem conta?
		<a href="/entrar" style="font-weight:600;color:#4E7468">Entrar</a>
	{/snippet}
</AuthCard>
