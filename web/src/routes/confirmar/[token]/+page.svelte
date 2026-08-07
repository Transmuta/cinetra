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
	import CartaoPaciente from '$lib/components/cinetra/CartaoPaciente.svelte';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envioPorItem } from '$lib/forms.svelte';
	import { canonizarTelefone, linkWhatsapp } from '$lib/telefone';
	import { descricaoDaSessao, linkGoogleAgenda, tituloDaSessao } from '$lib/calendario';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import CalendarPlus from '@lucide/svelte/icons/calendar-plus';
	import Check from '@lucide/svelte/icons/check';
	import Info from '@lucide/svelte/icons/info';
	import MessageCircle from '@lucide/svelte/icons/message-circle';
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

	// O canal de volta. WhatsApp primeiro: é onde a clínica já fala com o paciente, e é o único
	// dos dois que deixa a pessoa escrever fora do horário da recepção. O `tel:` fica como reserva
	// para o número que NÃO recebe WhatsApp — `wa.me` de um fixo abre o app só para dizer que
	// aquele número não existe lá (ver `linkWhatsapp`).
	const tel = $derived(canonizarTelefone(resumo?.clinica_telefone));

	// A conversa já começa dizendo de qual sessão se trata. Quem recebe é a recepção, com dezenas
	// de conversas abertas: sem isso, a primeira resposta dela é sempre "quem é?".
	const quandoEmTexto = $derived(
		quando ? `${quando.extenso}, às ${quando.hora}` : `${resumo?.data} às ${resumo?.hora}`
	);
	const euSou = $derived(resumo?.paciente ? `Sou ${resumo.paciente} e ` : '');
	const assunto = $derived(
		resumo?.ativa === false
			? `minha sessão de ${quandoEmTexto} foi cancelada. Gostaria de marcar outro horário.`
			: resumo?.resposta === 'quer_remarcar'
				? `preciso remarcar minha sessão de ${quandoEmTexto}.`
				: `tenho sessão em ${quandoEmTexto} e preciso falar com vocês.`
	);
	const zap = $derived(linkWhatsapp(resumo?.clinica_telefone, `Olá! ${euSou}${assunto}`));

	// Levar a sessão para o calendário. São DOIS caminhos porque um só não atende os dois celulares
	// (ver `$lib/calendario`): no Android o `.ics` cai em Downloads e nada abre sozinho, e no
	// iPhone o Google Agenda não aceita evento por link — lá o caminho é o `.ics`, que baixa e
	// abre no Calendário do aparelho. `null` quando a API não mandou instante: aí nenhum dos dois
	// leva a lugar nenhum, e o `.ics` responderia 404.
	const google = $derived(
		linkGoogleAgenda(
			{
				inicio: resumo?.inicio,
				fim: resumo?.fim,
				titulo: tituloDaSessao(resumo?.clinica),
				descricao: descricaoDaSessao(resumo?.clinica, resumo?.clinica_telefone)
			},
			// No Android o link vira `intent://`, que abre o APLICATIVO do Google Agenda; o
			// `https://` abriria o Agenda web dentro do Chrome. Vem do `load` (`user-agent`), não
			// daqui, para o SSR e a hidratação pintarem o mesmo `href`.
			{ android: data.android }
		)
	);

	// Dois botões, um form: a chave do "em voo" é o `value` do botão clicado. Quem responde por
	// WhatsApp está no celular, muitas vezes em rede ruim — sem sinal nenhum o toque parece
	// perdido e a pessoa toca no OUTRO botão, mandando a resposta contrária.
	const resposta = envioPorItem<string>();

	// Respondeu, acabou: os botões somem e não voltam. Deixá-los (ou oferecer um "mudar minha
	// resposta") convidaria ao segundo toque sem a pessoa saber se o primeiro valeu — e quem
	// realmente mudou de ideia tem um caminho melhor que um clique: falar com a clínica, que é
	// quem vai mexer na agenda de qualquer forma.
	const perguntando = $derived(!!resumo && !encerrada && !respondeu);
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
			{:else if zap || tel}
				A recepção resolve por lá: um horário novo depende da agenda, e nenhum clique daqui de
				fora conhece as regras dela.
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
				{#if zap}
					Para marcar um novo, é só chamar no WhatsApp.
				{:else if tel}
					Para marcar um novo, é só ligar.
				{:else}
					Fale com a clínica para marcar um novo.
				{/if}
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
			{#if respondeu}
				{#if resumo.resposta === 'confirmou'}
					<p class="cn-paciente-aviso cn-paciente-aviso-sim">
						<Check size={18} />
						<span>Presença confirmada. Até lá!</span>
					</p>
				{:else}
					<!-- Azul, e não verde: pedir remarcação não é um desfecho — é um pedido em aberto
					     que ainda depende de a clínica responder. Verde aqui dizia "resolvido" para
					     quem não tem horário nenhum. -->
					<p class="cn-paciente-aviso cn-paciente-aviso-espera">
						<CalendarClock size={18} />
						<span>Avisamos a clínica que você precisa remarcar. Em breve entram em contato.</span>
					</p>
				{/if}
			{/if}
		</div>

		{#if perguntando}
			<form method="POST" use:enhance={resposta.submitPeloBotao} class="cn-paciente-acoes">
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
			<!-- `google` é `null` sem instante, e aí não há evento a oferecer. -->
			{#if respondeu && resumo.resposta === 'confirmou' && !encerrada && google}
				<!-- Caminho ÚNICO para o calendário desde 2026-08-06. O `.ics` que ficava ao lado
				     foi retirado (com a rota que o servia): baixar arquivo é inviável no celular, e
				     isso foi medido nos dois sistemas — no Android ele cai em Downloads sem nada
				     abrir, e no iPhone vira uma folha de download que não leva a lugar nenhum. Ver
				     doc 104 §6.

				     Sem `target="_blank"` no Android: o `intent://` sai da aba para o aplicativo, e
				     abrir aba nova só deixaria uma em branco para trás. -->
				<a
					class="cn-paciente-link"
					href={google}
					target={data.android ? undefined : '_blank'}
					rel="noopener"
				>
					<CalendarPlus size={17} /> Adicionar ao Google Agenda
				</a>
			{/if}

			<!-- A única saída depois da resposta, e a única na sessão encerrada: falar com quem vai
			     mexer na agenda. Só aparece se houver número — botão que não leva a lugar nenhum é
			     pior que a ausência dele. -->
			{#if encerrada || respondeu}
				{#if zap}
					<a class="cn-paciente-link" href={zap} target="_blank" rel="noopener">
						<MessageCircle size={17} /> Falar com a clínica no WhatsApp
					</a>
				{:else if tel}
					<a class="cn-paciente-link" href="tel:{tel}">
						<Phone size={17} /> Ligar para a clínica
					</a>
				{/if}
			{/if}
		</div>
	</CartaoPaciente>
{/if}
