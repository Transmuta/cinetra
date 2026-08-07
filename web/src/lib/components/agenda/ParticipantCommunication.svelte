<script lang="ts">
	// A comunicação de UM participante, na linha dele (doc 109).
	//
	// A timeline do rodapé (`MessageTimeline`) continua sendo o histórico completo. O que mora
	// aqui é o resumo — uma frase — ao lado da pessoa de quem ele fala, mais o disparo por pessoa.
	//
	// ## Por que a ação mudou de lugar
	//
	// O "Reenviar" era da timeline, e isso obrigava a recepção a ler duas listas das MESMAS quatro
	// pessoas, separadas pelo painel inteiro, para responder "quem ainda não foi avisado?". A
	// decisão da linha (marcar presença, tirar da turma, avisar) acontece toda aqui em cima; a
	// comunicação era a única que ficava lá embaixo.
	//
	// Continua havendo **um** botão por disparo: ele saiu da timeline em vez de ganhar um irmão,
	// que é a mesma regra que tirou o antigo "Enviar agora" de lá — dois botões para o mesmo POST
	// davam duas respostas para a mesma pergunta.
	import Check from '@lucide/svelte/icons/check';
	import CircleAlert from '@lucide/svelte/icons/circle-alert';
	import Clock from '@lucide/svelte/icons/clock';
	import Minus from '@lucide/svelte/icons/minus';
	import Star from '@lucide/svelte/icons/star';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { comunicacaoDaPessoa, type MessageParticipant } from '$lib/messages';

	let {
		participante = undefined,
		carregando = false,
		timezone,
		agora,
		podeEnviar = false,
		emVoo = false,
		bloqueado = false,
		onEnviar
	}: {
		/**
		 * A linha deste paciente na resposta da timeline. `undefined` = a timeline não fala dele
		 * (ainda carregando, ou participante recém-adicionado que o próximo load traz).
		 */
		participante?: MessageParticipant;
		carregando?: boolean;
		timezone: string;
		/** O relógio do SERVIDOR (ADR-009) — decide se a previsão de envio ainda está no futuro. */
		agora: string;
		podeEnviar?: boolean;
		emVoo?: boolean;
		/** Outro disparo em voo: desabilita sem fingir que é este que está carregando. */
		bloqueado?: boolean;
		onEnviar?: (patientId: string) => void;
	} = $props();

	const c = $derived(participante ? comunicacaoDaPessoa(participante, agora) : null);

	// "ter 14:02" — mesma forma da timeline, e pelo mesmo motivo: data cheia numa linha de resumo
	// é ruído; o que a recepção precisa é "quando", em relação a hoje.
	function quando(iso: string | null): string {
		if (!iso) return '';
		return new Intl.DateTimeFormat('pt-BR', {
			weekday: 'short',
			hour: '2-digit',
			minute: '2-digit',
			timeZone: timezone
		}).format(new Date(iso));
	}

	const COR = {
		success: 'text-success',
		danger: 'text-danger',
		muted: 'text-muted',
		faint: 'text-faint'
	} as const;
</script>

{#if carregando && !participante}
	<!-- Carregando é diferente de "nada a dizer": o vazio aqui leria como "já resolvido", que é o
	     silêncio inexplicado que o §6 existe para impedir. -->
	<div class="mt-1 text-meta text-faint">Comunicação…</div>
{:else if c}
	<div class="mt-1 flex items-start gap-1.5 text-meta">
		<span class="mt-px shrink-0 {COR[c.tone]}">
			{#if c.tone === 'danger'}
				<CircleAlert size={12} />
			{:else if c.texto.startsWith('Confirmou')}
				<Star size={12} />
			{:else if c.tone === 'success'}
				<Check size={12} />
			{:else if c.previsao || c.tone === 'muted'}
				<Clock size={12} />
			{:else}
				<Minus size={12} />
			{/if}
		</span>

		<span class="min-w-0 flex-1 {COR[c.tone]}">
			{c.texto}
			{#if c.quando}
				<!-- Adiada pela janela de silêncio (§7): o instante útil é o FUTURO. "Entrou na fila às
				     22h" não responde a pergunta de quem está lendo. -->
				<span class="text-faint">· {c.previsao ? 'sai' : ''} {quando(c.quando)}</span>
			{/if}
		</span>

		{#if podeEnviar && participante}
			{#if c.acao}
				<!-- O `ariaLabel` nomeia a PESSOA: numa turma são quatro botões "Enviar" idênticos, e
				     sem isso quem navega por lista de botões ouve a mesma palavra quatro vezes sem
				     saber qual é qual. O rótulo visível continua contido no nome acessível (WCAG
				     2.5.3, Label in Name). -->
				<SubmitButton
					type="button"
					onclick={() => onEnviar?.(participante.patient_id)}
					{emVoo}
					disabled={bloqueado}
					ariaLabel="{c.acao} confirmação para {participante.paciente}"
					title="{c.acao} confirmação para {participante.paciente}"
					size={12}
					class="shrink-0 rounded-controle border border-edge px-1.5 py-0.5 text-meta font-semibold text-accent-text transition-colors hover:bg-surface-2 disabled:cursor-not-allowed disabled:opacity-55"
				>
					{c.acao}
				</SubmitButton>
			{:else if c.bloqueio}
				<!-- Sem botão, mas COM o porquê. Um vazio no lugar da ação faz a recepção procurar o
				     que não existe; o motivo aqui é o mesmo `{:skip, _}` que o servidor devolveria. -->
				<span class="shrink-0 text-faint" title={c.bloqueio}>—</span>
			{/if}
		{/if}
	</div>
{/if}
