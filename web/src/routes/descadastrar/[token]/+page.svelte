<script lang="ts">
	// A página de descadastro (doc 52 §10). Uma pergunta, um botão.
	//
	// Escrita para quem NÃO é usuário do sistema, como a de confirmação: sem jargão e sem saída
	// para dentro do produto. E ela **pergunta** antes de agir — abrir o link não tira ninguém da
	// lista, porque scanner de e-mail abre link sozinho.
	import { enhance } from '$app/forms';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envio as criarEnvio } from '$lib/forms.svelte';
	import BellOff from '@lucide/svelte/icons/bell-off';
	import Check from '@lucide/svelte/icons/check';
	import type { ActionData, PageData } from './$types';

	const envio = criarEnvio();

	let { data, form }: { data: PageData; form: ActionData } = $props();

	// A resposta do POST manda sobre a do load: depois de clicar, é o novo estado que vale.
	const resumo = $derived(form && 'resumo' in form ? form.resumo : data.resumo);
	const fora = $derived(!!resumo?.descadastrado);
</script>

<svelte:head>
	<title>Não receber mais avisos</title>
	<!-- Página de link privado: não deve ser indexada nem aparecer em busca. -->
	<meta name="robots" content="noindex, nofollow" />
</svelte:head>

<main class="mx-auto flex min-h-dvh max-w-md flex-col justify-center px-5 py-10">
	{#if !resumo}
		<div class="rounded-cartao border border-edge bg-surface p-6 text-center">
			<h1 class="text-titulo font-bold">
				{data.status === 410 ? 'Este link expirou' : 'Não encontramos este pedido'}
			</h1>
			<p class="mt-2 text-corpo text-muted">
				{data.status === 410
					? 'Links de descadastro valem por um ano.'
					: 'O link pode ter sido digitado incompleto.'}
				Fale com a clínica para parar de receber os avisos.
			</p>
		</div>
	{:else}
		<div class="rounded-cartao border border-edge bg-surface p-6">
			<p class="text-rotulo font-semibold tracking-wide text-accent uppercase">
				{resumo.clinica}
			</p>

			{#if fora}
				<h1 class="mt-2 text-destaque font-bold">Pronto, você saiu da lista</h1>

				<div
					class="mt-5 flex items-start gap-2 rounded-controle bg-success/10 px-4 py-3 text-corpo font-semibold text-success"
				>
					<span class="mt-0.5 shrink-0"><Check size={16} /></span>
					<span>
						A {resumo.clinica ?? 'clínica'} não enviará mais avisos de agendamento para este contato.
					</span>
				</div>

				<!-- O caminho de volta é pelo balcão, e é assim de propósito: reativar por um link
				     seria reativar por quem tem o link, não por quem é dono do contato. -->
				<p class="mt-4 text-corpo text-muted">
					Mudou de ideia? Peça na recepção para voltar a receber — leva um minuto.
				</p>
			{:else}
				<h1 class="mt-2 text-destaque font-bold">Não quer mais receber estes avisos?</h1>

				<p class="mt-1.5 text-leitura text-muted">
					Você deixa de receber as mensagens de agendamento da
					<strong class="text-ink">{resumo.clinica}</strong>: confirmação, remarcação e
					cancelamento das suas sessões.
				</p>

				<form method="POST" use:enhance={envio.submit} class="mt-5">
					<SubmitButton
						emVoo={envio.emVoo}
						size={17}
						class="flex w-full items-center justify-center gap-2 rounded-controle bg-accent px-4 py-3 text-leitura font-bold text-on-solid hover:opacity-90 disabled:opacity-60"
					>
						<BellOff size={17} /> Parar de receber
					</SubmitButton>
				</form>

				{#if form && 'error' in form && form.error}
					<p class="mt-3 text-corpo text-danger">{form.error}</p>
				{/if}
			{/if}
		</div>

		<!-- O que ela NÃO faz: cancelar sessão. Sem esta linha, alguém sai da lista achando que
		     desmarcou o tratamento — e some da agenda sem avisar ninguém. -->
		<p class="mt-4 text-center text-rotulo text-faint">
			Isto não cancela suas sessões. Para desmarcar, fale com a clínica.
		</p>
	{/if}
</main>
