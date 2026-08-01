<script lang="ts">
	// A timeline de comunicação de um agendamento (doc 52 §6) — o que a recepção lê para entender
	// "o que rolou" sem ligar para o paciente.
	//
	// Duas decisões deste componente vêm direto do doc e não são estéticas:
	//
	//  1. **agrupa por participante**, não por bloco. Numa turma de 4, "confirmação enviada" no
	//     bloco é falso para os outros 3 — é a mesma lição que a A2 já cobrou com a falta (§3);
	//  2. **o silêncio é uma linha, nunca ausência de linha**. Quem não recebeu nada aparece com o
	//     motivo — ou, quando não há motivo, com o `SEM_COMUNICACAO`. Silêncio na tela faz a
	//     recepção supor que a mensagem saiu, e isso é pior do que não ter a funcionalidade (§6).
	//
	// A timeline é **histórico, não ação**: o único botão que ela oferece é o "Reenviar" de uma
	// tentativa que falhou. A primeira mensagem sai pelo "Enviar confirmação" do rodapé do drawer,
	// que dispara para o bloco inteiro.
	import Check from '@lucide/svelte/icons/check';
	import CircleAlert from '@lucide/svelte/icons/circle-alert';
	import Clock from '@lucide/svelte/icons/clock';
	import Minus from '@lucide/svelte/icons/minus';
	import Star from '@lucide/svelte/icons/star';
	import {
		descarteTexto,
		instanteDoStatus,
		podeReenviar,
		previsaoDeEnvio,
		respostaTexto,
		SEM_COMUNICACAO,
		semEnvioTexto,
		statusTexto,
		tituloDaLinha,
		type Message,
		type MessageParticipant
	} from '$lib/messages';

	let {
		participantes,
		carregando = false,
		timezone,
		agora = undefined,
		podeEnviar = false,
		onReenviar
	}: {
		participantes: MessageParticipant[];
		carregando?: boolean;
		timezone: string;
		/** O relógio do servidor (ADR-009). Decide se a previsão de envio ainda está no futuro. */
		agora?: string;
		podeEnviar?: boolean;
		onReenviar?: (patient_id: string) => void;
	} = $props();

	// "ter 14:02" — dia da semana curto + hora, no fuso da clínica. Data cheia numa lista de 4
	// linhas vira ruído; o que a recepção precisa saber é "quando", em relação a hoje.
	function quando(iso: string | null): string {
		if (!iso) return '';
		return new Intl.DateTimeFormat('pt-BR', {
			weekday: 'short',
			hour: '2-digit',
			minute: '2-digit',
			timeZone: timezone
		}).format(new Date(iso));
	}

	function corDoStatus(m: Message): string {
		if (m.status === 'falhou') return 'text-danger';
		if (m.status === 'entregue' || m.status === 'lido') return 'text-success';
		return 'text-faint';
	}
</script>

<section class="border-t border-edge px-5 py-4">
	<h3 class="mb-3 text-meta font-bold tracking-wide text-faint uppercase">Comunicação</h3>

	{#if carregando}
		<p class="text-rotulo text-faint">Carregando…</p>
	{:else if participantes.length === 0}
		<p class="text-rotulo text-faint">Nada a mostrar.</p>
	{:else}
		<ul class="flex flex-col gap-3.5">
			{#each participantes as p (p.attendance_id)}
				<li>
					<!-- O nome só aparece quando há mais de um participante: numa sessão individual
					     ele repetiria o cabeçalho do drawer duas linhas acima. -->
					{#if participantes.length > 1}
						<p class="mb-1 text-rotulo font-semibold">{p.paciente}</p>
					{/if}

					<ul class="flex flex-col gap-1">
						{#each p.mensagens as m (m.id)}
							<li class="flex items-start gap-2 text-rotulo">
								<span class="mt-0.5 shrink-0 {corDoStatus(m)}">
									{#if m.status === 'falhou'}
										<CircleAlert size={14} />
									{:else if m.status === 'entregue' || m.status === 'lido'}
										<Check size={14} />
									{:else if m.status === 'descartada'}
										<!-- O mesmo traço do "nada enviado" logo abaixo, e de propósito: os dois
										     dizem que o paciente não recebeu nada. O relógio diria o contrário. -->
										<Minus size={14} />
									{:else}
										<Clock size={14} />
									{/if}
								</span>
								<span class="text-muted">
									{tituloDaLinha(m)} · <span class={corDoStatus(m)}>{statusTexto(m)}</span>
									{#if previsaoDeEnvio(m, agora)}
										<!-- A mensagem está parada porque a janela de silêncio a adiou (§7), não
										     porque falhou. Aqui o instante útil é o FUTURO: "entrou na fila às
										     22h" não responde a pergunta de quem está lendo. -->
										· sai {quando(previsaoDeEnvio(m, agora))}
									{:else if quando(instanteDoStatus(m))}
										· {quando(instanteDoStatus(m))}
									{/if}
									{#if descarteTexto(m)}
										<!-- Por que ela parou. Sem isto, "Não enviada" manda a recepção procurar um
										     defeito onde houve uma decisão (cancelar, excluir). -->
										· {descarteTexto(m)}
									{/if}
									{#if m.automatico}
										· automático
									{/if}
									{#if m.erro_texto}
										<span class="text-danger"> · {m.erro_texto}</span>
									{/if}
								</span>
							</li>

							{#if m.resposta}
								<!-- A resposta é o que a fatia inteira existe para capturar (§5): destacada,
								     e não mais uma linha cinza igual às outras. -->
								<li class="flex items-start gap-2 text-rotulo font-semibold text-accent">
									<span class="mt-0.5 shrink-0"><Star size={14} /></span>
									<span>
										{respostaTexto(m)}
										{#if quando(m.respondido_em)}
											· {quando(m.respondido_em)}
										{/if}
									</span>
								</li>
							{/if}
						{/each}

						{#if p.sem_envio}
							<li class="flex items-start gap-2 text-rotulo text-faint">
								<span class="mt-0.5 shrink-0"><Minus size={14} /></span>
								<span>{semEnvioTexto(p.sem_envio)}</span>
							</li>
						{:else if p.mensagens.length === 0}
							<!-- Nada saiu e nada barra: a linha é o §6 em vigor — sem ela este
							     participante ficaria com o nome e o vazio abaixo, e vazio na tela lê-se
							     como "já resolvido". A primeira mensagem sai pelo rodapé, não daqui. -->
							<li class="flex items-start gap-2 text-rotulo text-faint">
								<span class="mt-0.5 shrink-0"><Minus size={14} /></span>
								<span>{SEM_COMUNICACAO}</span>
							</li>
						{/if}
					</ul>

					{#if podeEnviar && podeReenviar(p) && onReenviar}
						<button
							type="button"
							onclick={() => onReenviar?.(p.patient_id)}
							class="mt-1.5 text-rotulo font-semibold text-accent hover:underline"
						>
							Reenviar
						</button>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}
</section>
