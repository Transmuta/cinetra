<script lang="ts">
	import { enhance } from '$app/forms';
	import AuthCard from '$lib/components/AuthCard.svelte';
	import Field from '$lib/components/Field.svelte';
	import Button from '$lib/components/Button.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	let submitting = $state(false);
	// Primeiro nome, para um cumprimento pessoal sem poluir o card.
	const primeiroNome = $derived(data.nome?.split(' ')[0] ?? '');
	// `nova`: dono existente criando uma clínica adicional pelo menu — muda o texto e mostra
	// um caminho de volta (ele já tem uma clínica ativa para onde voltar).
	const nova = $derived(data.nova ?? false);
</script>

<svelte:head><title>{nova ? 'Nova clínica' : 'Criar sua clínica'} · Cinetra</title></svelte:head>

<AuthCard
	title={nova ? 'Criar outra clínica' : 'Vamos criar sua clínica'}
	subtitle={nova
		? 'Dê um nome à nova clínica. Você entra nela assim que criar.'
		: primeiroNome
			? `Olá, ${primeiroNome}. Dê um nome à sua clínica para começar.`
			: 'Dê um nome à sua clínica para começar.'}
>
	<!-- Progressive enhancement: com JS envia sem reload; sem JS, submit nativo cai na mesma
	     action e o redirect vem por SSR. -->
	<form
		method="POST"
		use:enhance={() => {
			submitting = true;
			return async ({ update }) => {
				await update({ reset: false });
				submitting = false;
			};
		}}
	>
		<Field
			label="Nome da clínica"
			name="nome"
			value={form?.nome ?? ''}
			placeholder="Ex.: Clínica Reabilitar"
			required
			maxlength={160}
		/>

		{#if form?.error}
			<p class="mb-3 text-[12.5px] text-danger">{form.error}</p>
		{/if}

		<div class="mt-[6px]">
			<Button type="submit" disabled={submitting}>
				{submitting ? 'Criando…' : 'Criar clínica'}
			</Button>
		</div>
	</form>

	{#snippet footer()}
		{#if nova}
			Você será a <strong class="text-ink">dona</strong> desta clínica.
			<a class="ml-1 text-teal-text hover:underline" href="/">Voltar</a>
		{:else}
			Você será a <strong class="text-ink">dona</strong> desta clínica.
		{/if}
	{/snippet}
</AuthCard>
