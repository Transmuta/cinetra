<script lang="ts">
	// A página do paciente (doc 52 §5). Uma pergunta, dois botões.
	//
	// Escrita para quem NÃO é usuário do sistema: sem jargão, sem "voltar ao painel", sem nada
	// clicável além das duas respostas. Se o link não vale mais, a frase diz o que fazer — falar
	// com a clínica — em vez de mostrar um erro técnico.
	import { enhance } from '$app/forms';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envioPorItem } from '$lib/forms.svelte';
	import Check from '@lucide/svelte/icons/check';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import type { ActionData, PageData } from './$types';

	// Dois botões, um form: a chave do "em voo" é o `value` do botão clicado. Quem responde por
	// WhatsApp está no celular, muitas vezes em rede ruim — sem sinal nenhum o toque parece
	// perdido e a pessoa toca no OUTRO botão, mandando a resposta contrária.
	const resposta = envioPorItem<string>();

	let { data, form }: { data: PageData; form: ActionData } = $props();

	// A resposta do POST manda sobre a do load: depois de clicar, é o novo estado que vale.
	const resumo = $derived(form && 'resumo' in form ? form.resumo : data.resumo);
	const respondeu = $derived(!!resumo?.resposta);
</script>

<svelte:head>
	<title>Confirmar sessão</title>
	<!-- Página de link privado: não deve ser indexada nem aparecer em busca. -->
	<meta name="robots" content="noindex, nofollow" />
</svelte:head>

<main class="mx-auto flex min-h-dvh max-w-md flex-col justify-center px-5 py-10">
	{#if !resumo}
		<div class="rounded-xl border border-edge bg-surface p-6 text-center">
			<h1 class="text-[17px] font-bold">
				{data.status === 410 ? 'Este link expirou' : 'Não encontramos esta sessão'}
			</h1>
			<p class="mt-2 text-[13.5px] text-muted">
				{data.status === 410
					? 'Links de confirmação valem por 30 dias.'
					: 'O link pode ter sido digitado incompleto.'}
				Fale com a clínica para confirmar sua sessão.
			</p>
		</div>
	{:else}
		<div class="rounded-xl border border-edge bg-surface p-6">
			<p class="text-[12.5px] font-semibold tracking-wide text-accent uppercase">
				{resumo.clinica}
			</p>

			<h1 class="mt-2 text-[19px] font-bold">
				{resumo.paciente ? `Olá, ${resumo.paciente}!` : 'Olá!'}
			</h1>

			<p class="mt-1.5 text-[14px] text-muted">
				Sua sessão está marcada para <strong class="text-ink">{resumo.data}</strong> às
				<strong class="text-ink">{resumo.hora}</strong>.
			</p>

			{#if respondeu}
				<!-- Depois de responder, os botões somem. Deixá-los seria convidar a pessoa a clicar de
				     novo sem saber se a primeira valeu. -->
				<div
					class="mt-5 flex items-start gap-2 rounded-lg bg-success/10 px-4 py-3 text-[13.5px] font-semibold text-success"
				>
					<span class="mt-0.5 shrink-0">
						{#if resumo.resposta === 'confirmou'}<Check size={16} />{:else}<CalendarClock
								size={16}
							/>{/if}
					</span>
					<span>
						{#if resumo.resposta === 'confirmou'}
							Presença confirmada. Até lá!
						{:else}
							Avisamos a clínica que você precisa remarcar. Em breve entram em contato.
						{/if}
					</span>
				</div>
			{:else}
				<form method="POST" use:enhance={resposta.submitPeloBotao} class="mt-5 flex flex-col gap-2">
					<SubmitButton
						emVoo={resposta.emVoo('confirmou')}
						disabled={resposta.algumEmVoo}
						name="resposta"
						value="confirmou"
						size={17}
						class="flex items-center justify-center gap-2 rounded-lg bg-accent px-4 py-3 text-[14px] font-bold text-on-solid hover:opacity-90 disabled:opacity-60"
					>
						<Check size={17} /> Confirmar presença
					</SubmitButton>

					<SubmitButton
						emVoo={resposta.emVoo('quer_remarcar')}
						disabled={resposta.algumEmVoo}
						name="resposta"
						value="quer_remarcar"
						size={17}
						class="flex items-center justify-center gap-2 rounded-lg border border-edge px-4 py-3 text-[14px] font-semibold hover:bg-surface-2 disabled:opacity-60"
					>
						<CalendarClock size={17} /> Preciso remarcar
					</SubmitButton>
				</form>

				{#if form && 'error' in form && form.error}
					<p class="mt-3 text-[13px] text-danger">{form.error}</p>
				{/if}
			{/if}
		</div>

		<!-- Deixa explícito que pedir remarcação não remarca nada sozinho (§5): sem isso, alguém
		     fica esperando um horário novo que ninguém vai mandar automaticamente. -->
		<p class="mt-4 text-center text-[12px] text-faint">
			Pedir remarcação não escolhe um horário novo — a clínica entra em contato.
		</p>
	{/if}
</main>
