<script lang="ts">
	// O bloco do grid. Redesenhado no AN-01 (doc 64 §3) contra a Figura 2 do relatório de
	// homologação: **uma regra visual para cada informação**.
	//
	// O que mudou em relação ao desenho herdado do protótipo (`renderBlock` :1666), e por quê:
	//
	//  - o FUNDO deixou de ser o status. Antes três regras concorrentes pintavam o mesmo
	//    retângulo (`AÇÃO > conflito > status`), e a cor carregava quatro dimensões sem legenda
	//    nenhuma — o HOM-002. Agora o fundo é sempre `surface` e cada informação tem um canal
	//    próprio: status no ponto+badge, profissional na faixa lateral, conflito e encaixe em
	//    ícone com rótulo, pendência no verbo;
	//  - o status passou a ser ESCRITO. Antes existia só como tinta, opacidade e tachado — o
	//    texto vivia apenas no `aria-label`, o que é acessível e invisível ao mesmo tempo;
	//  - a linha 1 tinha SEIS sinais (ponto do profissional, conflito, badge AÇÃO, ícone do
	//    tipo, pulso de "em atendimento", badge ENCAIXE) e um único `title` — o HOM-004. Sobram
	//    dois ícones, ambos com rótulo: conflito e encaixe. O ícone do tipo saiu porque o NOME
	//    do tipo já é a linha 3; o pulso saiu porque o badge agora diz "Em atendimento".
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Zap from '@lucide/svelte/icons/zap';
	import Package from '@lucide/svelte/icons/package';
	import Star from '@lucide/svelte/icons/star';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import { statusSignal, packageBadge, replyBadges, type Appointment } from '$lib/agenda';
	import { blockGeometry, type Slot } from '$lib/agenda-layout';
	import type { AgendaAppointmentType } from '$lib/agenda';

	let {
		appt,
		tipo = undefined,
		slot,
		top,
		height,
		conflict = false,
		action = false,
		dragging = false,
		patientNames = [],
		profColor,
		startLabel,
		onSelect
	}: {
		appt: Appointment;
		tipo?: AgendaAppointmentType;
		slot: Slot;
		top: number;
		height: number;
		/** Sobrepõe outro agendamento do mesmo profissional (exibição — ver A-D2). */
		conflict?: boolean;
		/** Já terminou e ninguém resolveu (RN-58). */
		action?: boolean;
		/**
		 * Este é o bloco em arraste: esmaece para 0.4 enquanto o fantasma mostra o destino
		 * (protótipo `dragging` [`:1684`]). É o par visual do ghost — sem ele o bloco de origem
		 * fica parado e nada sinaliza que está "no ar".
		 */
		dragging?: boolean;
		patientNames?: string[];
		profColor: string;
		startLabel: string;
		onSelect: (id: string) => void;
	} = $props();

	const geo = $derived(blockGeometry(slot));

	const grupo = $derived(!!tipo?.grupo);
	const capacidade = $derived(tipo?.capacidade ?? 4);

	// O sinal (ponto + badge) sai de uma fonte só, que sabe quando a palavra do status mente
	// numa turma mista — ver `statusSignal` e o §3.2 do doc 64.
	const sinal = $derived(statusSignal(appt, grupo));

	// A pendência é ORTOGONAL ao status (um bloco agendado OU confirmado pode precisar de
	// ação), então ela não entra na mesma fileira conceitual — ela SUBSTITUI o badge quando
	// está ativa, porque "Agendado" e "Registrar status" lado a lado seria dizer duas vezes
	// que ninguém resolveu. O verbo é um só: o gatilho é um só (RN-58, D2 do doc 64).
	const badge = $derived(action ? { label: 'Registrar status', tone: 'warning' as const } : sinal);

	const titulo = $derived(
		grupo && tipo
			? tipo.nome
			: // Um id sem correspondência no sidecar (paciente removido entre a leitura e o
				// render) vira um rótulo neutro — nunca o nome do TIPO, que faria um bloco
				// anônimo passar por um bloco identificado.
				(patientNames[0] ?? 'Paciente')
	);

	// HOM-005: o contador era `Tipo · 2/4` no título, e "2/4" sozinho não diz de quê. Vira
	// linha própria, com a palavra que faltava.
	const vagas = $derived(`${appt.patient_ids.length}/${capacidade} vagas ocupadas`);

	// O pacote é do PARTICIPANTE (D11) e vem resolvido do servidor — o cartão não busca nada e não
	// conta nada: `packageBadge` só escolhe entre "a posição na série" e "quantos em pacote".
	const pacote = $derived(packageBadge(appt));

	// A resposta do paciente ao link (doc 52 §5). Mora na LINHA 1, junto de conflito e encaixe, e
	// não na terceira como o selo de pacote: a linha 1 é a única que existe em toda variante da
	// escada abaixo, e "o paciente confirmou" é justamente o que a recepção varre a tela para ver.
	// Na sessão de 15 min o selo de pacote desaparece; a estrela não pode.
	const respostas = $derived(replyBadges(appt));

	// O ícone é do TIPO de resposta; o `title` escreve por extenso, como o conflito e o encaixe.
	// `Star` é o mesmo glifo que a timeline do drawer usa para a resposta (doc 52 §6) — um sinal,
	// duas superfícies; `CalendarClock` é o mesmo de "Remarcar sessão" no rodapé do drawer.
	const ICONE_DA_RESPOSTA = { confirmou: Star, quer_remarcar: CalendarClock };

	// Teal para a confirmação (é a cor do sinal no drawer), âmbar para o pedido de remarcação —
	// que é o único dos dois que pede ação de alguém.
	const TOM_DA_RESPOSTA = { confirmou: 'text-accent', quer_remarcar: 'text-warning' };

	const rotulo = $derived(
		[
			startLabel,
			titulo,
			tipo?.nome,
			appt.encaixe ? 'encaixe' : null,
			pacote?.title,
			// No rótulo acessível a resposta entra SEMPRE, mesmo quando o ícone cabe na tela: o
			// leitor de tela não tem `title` de ícone para consultar.
			...respostas.map((r) => r.title),
			badge.label
		]
			.filter(Boolean)
			.join(' · ')
	);

	// Escada de degradação (D1 do doc 64), com os limiares **medidos** — não estimados.
	//
	// A primeira versão chutou `76/44/30` e a medição ao vivo mostrou que dois deles cortavam
	// texto: o card é `flex flex-col` com `overflow-hidden`, então quando não cabe os filhos
	// **encolhem** em vez de estourar. Nada quebra visivelmente; a linha do nome só fica com 9px
	// em vez de 18 e o texto some pela metade. Medido no browser, cada variante precisa de:
	//
	//   compacta →  hora + nome na MESMA linha  + padding(8)          = 24px
	//   2 linhas →  hora(16) + nome 12px(18)   + padding(8) + gap(2)  = 44px
	//   3 linhas →  + tipo/pacientes(15) + gap(2)                     = 61px
	//   4 linhas →  + vagas(15) + gap(2)   (só turma usa a quarta)    = 78px
	//
	// Abaixo de 44 nem duas linhas empilhadas cabem — empilhada, a dupla hora+nome pediria 41px.
	// É por isso que a variante de baixo **não empilha**: ela sobe o nome para a linha da hora e
	// passa a caber em 24. Sem essa troca, a sessão de 15 min renderizava o nome com 9px.
	//
	// A conta é sobre a altura **renderizada**, não a recebida: o `style` abaixo desenha
	// `height - 2` (a folga entre blocos vizinhos), e comparar a de entrada escolhia a variante
	// por 2px que não existem na tela — o bastante para o card de 30 min pedir duas linhas num
	// espaço de uma.
	const util = $derived(Math.max(height - 2, 18));
	const linhas = $derived(util >= 78 ? 4 : util >= 61 ? 3 : util >= 44 ? 2 : 1);

	// A cor sai de `color-mix` sobre o token do tema, e não de um hex calculado em JS: o valor
	// do token muda entre claro e escuro, e um hex congelado quebraria o modo escuro.
	//
	// O `null` aqui é só o da TURMA MISTA (o sinal deixou de ser um status e virou composição) —
	// todo status tem tom próprio desde que `agendado` e `cancelado` deixaram de compartilhar o
	// mesmo cinza implícito.
	const corDoTom = (tom: string | null) => (tom ? `var(--color-${tom})` : 'var(--color-muted)');

	// A borda só é tingida pelo que EXIGE atenção — conflito e pendência. O status não pinta
	// mais nada além do ponto e do badge; a faixa lateral é do profissional.
	//
	// **A precedência inverteu, e de propósito.** O protótipo mandava `AÇÃO > conflito` (:1666),
	// e fazia sentido enquanto as duas disputavam o FUNDO inteiro do bloco — só uma podia
	// vencer, e a pendência era a mais acionável. Agora não disputam mais o mesmo canal: a
	// pendência tem o badge inteiro ("Registrar status", com a cor dela), e ao conflito sobra um
	// ícone de 11px. Se a borda continuasse indo para a pendência, o bloco em conflito *e*
	// pendente sinalizaria a pendência duas vezes e o conflito nenhuma. Então a borda vai para o
	// conflito, que é o fato mais grave e o que tem menos voz.
	const stroke = $derived(
		conflict ? 'var(--color-danger)' : action ? 'var(--color-warning)' : 'var(--color-edge)'
	);
</script>

<button
	type="button"
	data-appt
	data-appt-id={appt.id}
	data-variant={conflict ? 'conflict' : action ? 'action' : 'status'}
	data-strike={sinal.strike ? 'true' : undefined}
	data-linhas={linhas}
	aria-label={rotulo}
	onclick={(e) => {
		e.stopPropagation();
		onSelect(appt.id);
	}}
	style="top:{top}px; height:{util}px; left:{geo.left}; width:{geo.width};
	       background:var(--color-surface); border-color:{stroke}; border-left-color:{profColor};
	       opacity:{dragging ? 0.4 : sinal.dim ? 0.72 : 1};
	       transition:opacity .15s;
	       border-width:{conflict || action ? 1.5 : 1}px; border-left-width:3px;
	       z-index:{conflict ? 3 : 2};"
	class="absolute flex flex-col gap-0.5 overflow-hidden rounded-controle border border-solid px-1.5 py-1 text-left"
>
	<div class="flex items-center gap-1.25">
		<!-- Ponto e hora na cor do STATUS (Figura 2, regra 2). O ponto do profissional saiu
		     daqui: a cor dele agora é a faixa lateral esquerda, que não disputa a linha 1. -->
		<span
			class="size-1.5 shrink-0 rounded-full"
			style="background:{corDoTom(sinal.tone)}"
			data-testid="status-dot"
		></span>
		<span
			class="font-mono text-micro font-semibold tabular-nums"
			style="color:{corDoTom(sinal.tone)}">{startLabel}</span
		>

		{#if conflict}
			<span title="Conflito de horário" class="shrink-0 text-danger">
				<TriangleAlert size={11} />
			</span>
		{/if}

		{#if appt.encaixe}
			<span title="Encaixe — marcado fora da grade" class="shrink-0 text-warning">
				<Zap size={11} />
			</span>
		{/if}

		<!-- Ícone COM rótulo, como os dois acima: o número é o rótulo e só aparece quando há mais de
		     um respondente na turma — uma estrela solta num bloco de quatro não diria quantos
		     confirmaram. O `title` escreve a frase inteira nos dois casos. -->
		{#each respostas as r (r.kind)}
			{@const Icone = ICONE_DA_RESPOSTA[r.kind]}
			<span
				title={r.title}
				data-testid="reply-{r.kind}"
				class="flex shrink-0 items-center gap-0.5 {TOM_DA_RESPOSTA[r.kind]}"
			>
				<Icone size={11} />
				{#if r.label}
					<span class="text-micro font-bold tabular-nums">{r.label}</span>
				{/if}
			</span>
		{/each}

		{#if linhas === 1}
			<!-- Variante compacta: o nome sobe para a MESMA linha da hora. Empilhado ele precisaria
			     de 41px e aqui há ~20 — o que acontecia era o flex encolher a linha do nome para 9px
			     e cortar o texto no meio, em silêncio. Numa linha só, cabe. O status vive no ponto,
			     e o resto no `aria-label`. -->
			<span class="truncate text-micro {sinal.strike ? 'text-faint line-through' : 'text-ink'}">
				{titulo}
			</span>
		{:else}
			<span
				data-testid="status-badge"
				class="ml-auto truncate rounded-micro px-1 py-px text-micro font-bold"
				style="color:{badge.tone
					? `var(--color-${badge.tone}-text, var(--color-${badge.tone}))`
					: 'var(--color-muted)'};
				       background:color-mix(in srgb, {corDoTom(badge.tone)} 12%, transparent)"
			>
				{badge.label}
			</span>
		{/if}
	</div>

	{#if linhas > 1}
		<div
			class="truncate text-rotulo font-semibold {sinal.strike
				? 'text-faint line-through'
				: 'text-ink'}"
		>
			{titulo}
		</div>
	{/if}

	{#if linhas > 2}
		<div class="flex items-center gap-1">
			<span class="min-w-0 flex-1 truncate text-micro text-faint">
				{#if grupo}
					{patientNames.slice(0, 3).join(', ')}{appt.patient_ids.length > 3
						? ` +${appt.patient_ids.length - 3}`
						: ''}
				{:else}
					{tipo?.nome ?? ''}
				{/if}
			</span>

			<!-- O selo de pacote divide a linha do detalhe em vez de ganhar uma quarta linha: a
			     quarta só existe acima de 78px (a turma usa para as vagas), e a sessão de 30 min
			     — que é pacote com a mesma frequência das outras — nunca a alcançaria. Aqui ele
			     aparece a partir de 61px, junto do tipo/pacientes que ele complementa.

			     Ícone COM rótulo, como o conflito e o encaixe da linha 1 (doc 64 §3): o número é o
			     rótulo, e o `title` escreve por extenso o que ele conta — que é o que muda entre a
			     sessão individual ("3/10") e a turma ("2"). Sem o número, sobra o ícone dizendo
			     "isto é pacote", que é mais do que o cartão dizia antes. -->
			{#if pacote}
				<span
					data-testid="package-badge"
					title={pacote.title}
					class="flex shrink-0 items-center gap-0.5 rounded-micro bg-accent-subtle px-1 py-px text-micro font-bold text-accent-text"
				>
					<Package size={9} />
					{pacote.label ?? ''}
				</span>
			{/if}
		</div>
	{/if}

	{#if linhas > 3 && grupo}
		<!-- Sem `mt-auto`: com `PPM = 2.55` o bloco de 50min tem 126px e sobra folga embaixo, então
		     empurrar esta linha para o rodapé a desgrudava das outras três — na tela ela parecia
		     legenda do bloco de baixo. As quatro linhas ficam juntas no topo, e a folga fica onde
		     folga deve ficar: no fim. Só a imagem mostrou isso; a escada passava verde. -->
		<div class="truncate text-micro font-medium text-muted">{vagas}</div>
	{/if}
</button>
