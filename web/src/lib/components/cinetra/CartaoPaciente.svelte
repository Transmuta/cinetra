<script lang="ts">
	// A moldura das telas que o **paciente** abre por link (`/confirmar`, `/descadastrar`).
	//
	// Ela existe para uma coisa: fazer a página parecer a continuação do e-mail que a trouxe. O
	// paciente não conhece a Cinetra — ele conhece a clínica —, e a mensagem que ele acabou de ler
	// tem o nome dela num bloco navy, uma régua sálvia embaixo, o telefone, e a Cinetra só no
	// rodapé (`Api.EmailLayout.cabecalho_clinica/2`). Aqui é a mesma peça, nos mesmos hex.
	//
	// `data-theme="light"` + `color-scheme:light`, como no `AuthCard` e pela mesma razão: papel e
	// navy são PIGMENTO da marca, não superfície de app. Sem isso a página seguia o
	// `prefers-color-scheme` do aparelho (o paciente não tem cookie de tema), e quem lê no escuro
	// recebia e-mail creme e abria uma página quase preta — a um clique de distância.
	import type { Snippet } from 'svelte';
	import Logo from '../Logo.svelte';
	import { canonizarTelefone } from '$lib/telefone';
	import '$lib/styles/cinetra.css';

	let {
		clinica,
		telefone = null,
		children,
		nota
	}: {
		clinica: string | null;
		telefone?: string | null;
		children: Snippet;
		/** O que a tela NÃO faz. Fora do cartão: é sobre a página, não sobre a sessão. */
		nota?: Snippet;
	} = $props();

	// `tel:` quer E.164, e canonizar é o que `telefone.ts` já sabe fazer. Número que não canoniza
	// (texto livre antigo na ficha da clínica) vira texto sem link — melhor que um `tel:` que o
	// discador abre e não completa.
	const href = $derived(canonizarTelefone(telefone));
</script>

<div class="cn-root cn-paciente" data-theme="light" style="color-scheme:light">
	<main class="cn-paciente-cartao">
		<div class="cn-paciente-topo">
			{#if clinica}
				<!-- Não é `h1`: o título da página é o que se pergunta ao paciente, não a marca de
				     quem pergunta. -->
				<p class="cn-paciente-clinica">{clinica}</p>
			{:else}
				<!-- Sem clínica conhecida (link inválido ou vencido), quem assina é a Cinetra: um
				     cabeçalho vazio deixaria a página órfã justo no estado em que ela mais precisa
				     parecer confiável. -->
				<Logo class="h-5 w-auto" />
			{/if}

			<div class="cn-paciente-regua"></div>

			{#if telefone}
				{#if href}
					<a class="cn-paciente-tel" href="tel:{href}">{telefone}</a>
				{:else}
					<span class="cn-paciente-tel">{telefone}</span>
				{/if}
			{/if}
		</div>

		<div class="cn-paciente-corpo">
			{@render children()}
		</div>
	</main>

	{#if nota}
		<p class="cn-paciente-nota">{@render nota()}</p>
	{/if}

	{#if clinica}
		<!-- A mesma assinatura do rodapé do e-mail, palavra por palavra. Some quando é a própria
		     Cinetra que assina o topo: a marca duas vezes na mesma tela vira ruído, e o rodapé
		     existe para dizer quem entrega — não para se repetir. -->
		<p class="cn-paciente-assinatura">
			Agenda e confirmações por <Logo class="h-3 w-auto" />
		</p>
	{/if}
</div>
