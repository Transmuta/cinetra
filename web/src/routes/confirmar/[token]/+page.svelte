<script lang="ts">
	// A página do paciente (doc 52 §5). Uma pergunta, dois botões.
	//
	// Escrita para quem NÃO é usuário do sistema: sem jargão, sem "voltar ao painel", sem nada
	// clicável que leve para dentro do produto. Se o link não vale mais, a frase diz o que fazer —
	// falar com a clínica, com o número na mão — em vez de mostrar um erro técnico.
	//
	// A moldura é o `CartaoPaciente`, que é a mesma peça do cabeçalho do e-mail. O que esta tela
	// acrescenta é a **decisão**: o quando em destaque, as duas respostas, e o que vem depois de
	// cada uma.
	import { enhance } from '$app/forms';
	import { page } from '$app/state';
	import CartaoPaciente from '$lib/components/cinetra/CartaoPaciente.svelte';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envioPorItem } from '$lib/forms.svelte';
	import { canonizarTelefone } from '$lib/telefone';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import CalendarPlus from '@lucide/svelte/icons/calendar-plus';
	import Check from '@lucide/svelte/icons/check';
	import Info from '@lucide/svelte/icons/info';
	import Phone from '@lucide/svelte/icons/phone';
	import type { ActionData, PageData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	// A resposta do POST manda sobre a do load: depois de clicar, é o novo estado que vale.
	const resumo = $derived(form && 'resumo' in form ? form.resumo : data.resumo);
	const quando = $derived(form && 'quando' in form ? form.quando : data.quando);
	const respondeu = $derived(!!resumo?.resposta);

	// Uma sessão cancelada ou já passada não se confirma. O link vale 30 dias e a sessão não: sem
	// estas duas, a tela oferecia "confirmar presença" para algo que não existe mais.
	const encerrada = $derived(!!resumo && (resumo.ativa === false || !!quando?.passou));

	const tel = $derived(canonizarTelefone(resumo?.clinica_telefone));

	// "Mudar minha resposta": some por padrão e é preciso pedir. Deixar os dois botões na tela
	// depois de responder convidaria ao segundo toque sem saber se o primeiro valeu — mas não ter
	// saída nenhuma faz quem tocou errado ligar para a clínica, que é o custo que esta tela existe
	// para evitar.
	let revendo = $state(false);

	// Dois botões, um form: a chave do "em voo" é o `value` do botão clicado. Quem responde por
	// WhatsApp está no celular, muitas vezes em rede ruim — sem sinal nenhum o toque parece
	// perdido e a pessoa toca no OUTRO botão, mandando a resposta contrária.
	const resposta = envioPorItem<string>({
		// Trocou a resposta? O formulário se fecha e a caixa nova aparece. **Só no sucesso**: se o
		// POST falhou, fechar esconderia os botões e o erro junto, e a pessoa ficaria com a resposta
		// antiga na tela sem saber que a troca não valeu.
		aoResponder: (result) => {
			if (result.type === 'success') revendo = false;
		}
	});

	const perguntando = $derived(!!resumo && !encerrada && (!respondeu || revendo));
</script>

<svelte:head>
	<title>Confirmar sessão</title>
	<!-- Página de link privado: não deve ser indexada nem aparecer em busca. -->
	<meta name="robots" content="noindex, nofollow" />
</svelte:head>

{#if !resumo}
	<!-- Sem resumo não há clínica para anunciar, e o cartão assina como Cinetra. -->
	<CartaoPaciente clinica={null}>
		<h1>{data.status === 410 ? 'Este link expirou' : 'Não encontramos esta sessão'}</h1>
		<p>
			{data.status === 410
				? 'Links de confirmação valem por 30 dias.'
				: 'O link pode ter sido digitado incompleto.'}
			Fale com a clínica para confirmar sua sessão.
		</p>
	</CartaoPaciente>
{:else}
	<CartaoPaciente clinica={resumo.clinica} telefone={resumo.clinica_telefone}>
		{#snippet nota()}
			{#if !encerrada}
				<!-- Deixa explícito que pedir remarcação não remarca nada sozinho (§5): sem isso,
				     alguém fica esperando um horário novo que ninguém vai mandar automaticamente. -->
				Pedir remarcação não escolhe um horário novo — a clínica entra em contato.
			{:else if tel}
				A recepção resolve pelo telefone: um horário novo depende da agenda, e nenhum clique
				daqui de fora conhece as regras dela.
			{/if}
		{/snippet}

		<h1>
			{#if encerrada}
				{resumo.ativa === false ? 'Esta sessão foi cancelada' : 'Essa sessão já passou'}
			{:else}
				{resumo.paciente ? `Olá, ${resumo.paciente}!` : 'Olá!'}
			{/if}
		</h1>

		{#if encerrada}
			<p>
				{resumo.ativa === false
					? 'A clínica cancelou este horário depois que a mensagem foi enviada.'
					: 'O horário abaixo já aconteceu.'}
				{tel ? 'Para marcar um novo, é só ligar.' : 'Fale com a clínica para marcar um novo.'}
			</p>
		{:else if !respondeu}
			<!-- A instrução sai depois da resposta: mantida, ela continuaria pedindo o que a pessoa
			     acabou de fazer, logo acima da caixa que diz que já está feito. -->
			<p>Confirme sua presença para a clínica saber que você vem.</p>
		{/if}

		<!-- O QUANDO em destaque, e não dentro de uma frase: quem abre isto no ônibus está
		     decidindo se sai de casa. `quando` vem calculado do servidor; sem ele (mensagem antiga,
		     sem instante na API) cai na data congelada, que é pior de ler mas continua verdadeira. -->
		<div class="cn-paciente-quando">
			{#if quando?.proximidade && !encerrada}
				<span class="cn-paciente-selo">{quando.proximidade}</span>
			{/if}
			<strong class="cn-paciente-hora">{quando?.hora ?? resumo.hora}</strong>
			<span class="cn-paciente-dia">{quando?.extenso ?? resumo.data}</span>
		</div>

		<!-- O resultado é anunciado a leitor de tela: os botões somem no mesmo instante, e sem isto
		     quem navega por teclado fica sem foco e sem notícia do que aconteceu. -->
		<div aria-live="polite">
			{#if respondeu && !revendo}
				{#if resumo.resposta === 'confirmou'}
					<p class="cn-paciente-aviso cn-paciente-aviso-sim">
						<Check size={18} />
						<span>Presença confirmada. Até lá!</span>
					</p>
				{:else}
					<!-- Azul, e não verde: pedir remarcação não é um desfecho — é um pedido em aberto
					     que ainda depende de a clínica ligar. Verde aqui dizia "resolvido" para quem
					     não tem horário nenhum. -->
					<p class="cn-paciente-aviso cn-paciente-aviso-espera">
						<CalendarClock size={18} />
						<span>Avisamos a clínica que você precisa remarcar. Em breve entram em contato.</span>
					</p>
				{/if}
			{/if}
		</div>

		{#if perguntando}
			<form method="POST" use:enhance={resposta.submitPeloBotao} class="cn-paciente-acoes">
				{#if revendo}
					<p class="cn-paciente-troca">
						Sua resposta agora é
						<strong
							>{resumo.resposta === 'confirmou'
								? 'presença confirmada'
								: 'preciso remarcar'}</strong
						>. Toque na outra opção para trocar.
					</p>
				{/if}

				<SubmitButton
					emVoo={resposta.emVoo('confirmou')}
					disabled={resposta.algumEmVoo}
					name="resposta"
					value="confirmou"
					size={18}
					class="cn-paciente-btn cn-paciente-btn-sim"
				>
					<Check size={18} /> Confirmar presença
				</SubmitButton>

				<SubmitButton
					emVoo={resposta.emVoo('quer_remarcar')}
					disabled={resposta.algumEmVoo}
					name="resposta"
					value="quer_remarcar"
					size={18}
					class="cn-paciente-btn cn-paciente-btn-nao"
				>
					<CalendarClock size={18} /> Preciso remarcar
				</SubmitButton>
			</form>

			{#if form && 'error' in form && form.error}
				<p class="cn-paciente-aviso cn-paciente-aviso-atencao">
					<Info size={18} />
					<span>{form.error}</span>
				</p>
			{/if}
		{/if}

		<!-- O que vem DEPOIS da resposta. Antes daqui a tela acabava numa caixa verde e num beco:
		     quem confirmou não tinha o que fazer, e quem pediu remarcação — que é justamente quem
		     tem um problema — ficava sem nenhuma saída na mão. -->
		<div class="cn-paciente-secundarias">
			{#if respondeu && !revendo && resumo.resposta === 'confirmou' && !encerrada}
				<!-- Caminho absoluto: relativo a `/confirmar/<token>` (sem barra no fim), um
				     `sessao.ics` solto resolveria para `/confirmar/sessao.ics`. E
				     `data-sveltekit-reload` porque o destino é um arquivo, não uma rota do app. -->
				<a class="cn-paciente-link" href="{page.url.pathname}/sessao.ics" data-sveltekit-reload>
					<CalendarPlus size={17} /> Adicionar à agenda
				</a>
			{/if}

			{#if tel && (encerrada || (respondeu && !revendo && resumo.resposta === 'quer_remarcar'))}
				<a class="cn-paciente-link" href="tel:{tel}">
					<Phone size={17} /> Ligar para a clínica
				</a>
			{/if}

			{#if respondeu && !encerrada}
				<button type="button" class="cn-paciente-desfazer" onclick={() => (revendo = !revendo)}>
					{revendo ? 'Deixar como está' : 'Mudar minha resposta'}
				</button>
			{/if}
		</div>
	</CartaoPaciente>
{/if}
