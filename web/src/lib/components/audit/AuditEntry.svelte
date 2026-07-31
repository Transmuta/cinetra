<script lang="ts">
	import CalendarSearch from '@lucide/svelte/icons/calendar-search';
	import CirclePlus from '@lucide/svelte/icons/circle-plus';
	import CircleMinus from '@lucide/svelte/icons/circle-minus';
	import Eye from '@lucide/svelte/icons/eye';
	import History from '@lucide/svelte/icons/history';
	import ShieldAlert from '@lucide/svelte/icons/shield-alert';
	import RefreshCw from '@lucide/svelte/icons/refresh-cw';
	import {
		auditHref,
		dayKey,
		entryAppointmentId,
		entryContext,
		entryHeadline,
		entrySessionAt,
		formatAt,
		formatTime,
		type AuditEntry
	} from '$lib/audit';
	import { appointmentHref } from '$lib/agenda';
	import FieldDiff from './FieldDiff.svelte';

	// Uma entrada do feed de auditoria (doc 25 §11.4), em três níveis:
	//
	//   1. o FATO — verbo de ator + objeto ("Adicionou Mariana ao atendimento");
	//   2. o CONTEXTO — de qual sessão se fala ("Dra. Bea · ter 20/07, 09:00");
	//   3. o AUTOR e os links ("por Fulano").
	//
	// A versão anterior era uma frase só (`{ator} {verbo} · {contexto}`), e ela AFIRMAVA COISA
	// ERRADA no participante: os verbos de `attendance` estavam escritos na perspectiva do
	// paciente, com o ator como sujeito — "Fulano entrou na turma · Mariana". Quem entrou foi a
	// Mariana. Hoje o objeto entra dentro da frase (`entryHeadline`) e o ator desce de nível.
	//
	// `entry.at` é QUANDO o evento aconteceu; o horário da SESSÃO (quando há um) vem de `meta` —
	// os dois são coisas diferentes e por isso aparecem em lugares diferentes.
	let { entry, timezone }: { entry: AuditEntry; timezone: string } = $props();

	const actorName = $derived(entry.actor?.nome ?? 'Sistema');
	const headline = $derived(entryHeadline(entry));
	const context = $derived(entryContext(entry, timezone));

	// Ícone e cor pelo TIPO da ação: criar, alterar e destruir precisam pesar diferente numa
	// varredura. Antes as três renderizavam idênticas, e a âncora à esquerda era o avatar do
	// ator — o dado menos discriminante do feed (num dia típico, todas as linhas têm o mesmo).
	//
	// `read` e `deny` entraram com a trilha de leitura e a de autorização negada (doc 63): uma
	// consulta não é uma alteração, e uma tentativa barrada não é nenhuma das duas — pintá-las
	// como `update` diria que algo mudou quando nada mudou.
	const TONE = {
		create: { icon: CirclePlus, klass: 'text-success' },
		update: { icon: RefreshCw, klass: 'text-info' },
		destroy: { icon: CircleMinus, klass: 'text-danger' },
		read: { icon: Eye, klass: 'text-faint' },
		deny: { icon: ShieldAlert, klass: 'text-warning' }
	} as const;
	// `exclude` é soft-delete: é `update` no schema, mas para quem audita é uma exclusão.
	const tone = $derived(
		entry.action === 'exclude' || entry.action === 'remove' || entry.action === 'cancel'
			? TONE.destroy
			: (TONE[entry.action_type] ?? TONE.update)
	);

	// "Ver na agenda" leva ao AGENDAMENTO da linha (doc 85), com o dia ao lado. Depende de
	// `starts_at`, que o participante também tem (a API o enriquece a partir do bloco) — some só
	// quando o bloco não é mais legível, p.ex. depois de excluído.
	//
	// O id sai de onde ele mora em cada natureza de linha: na de AGENDAMENTO o próprio registro
	// tocado é o bloco; na de PRESENÇA o registro é a presença, e o bloco vem no contexto. Auditar
	// é ler uma linha e querer ver o que ela descreve — e levar ao dia deixava a última busca para
	// o auditor, num feed em que todas as linhas de um profissional se parecem.
	//
	// A data continua no link porque é ela o degrau de queda: numa trilha se lê justamente o que
	// mudou, e um bloco remarcado depois (ou excluído) ainda abre o dia de que a linha fala.
	const sessionAt = $derived(entrySessionAt(entry));
	const blocoId = $derived(
		entry.resource === 'appointment' ? entry.record_id : entryAppointmentId(entry)
	);
	const agendaHref = $derived(
		sessionAt ? appointmentHref(blocoId, dayKey(sessionAt, timezone)) : null
	);

	// "Ver histórico" isola a cadeia deste registro (`?record_id=`). O filtro sempre existiu na
	// API e no load; o que faltava era **entrada** para ele — sem este link, só chegava lá quem
	// digitasse a URL à mão.
	//
	// Sem `resource`: `record_id` é um uuid, único no sistema inteiro, e o feed unificado (doc 63)
	// mostra a vida do registro sem precisar saber de que tipo ele é. Antes era preciso casar o
	// grupo com o recurso, porque o filtro de recurso era o eixo que trocava a tabela lida.
	const historyHref = $derived(
		entry.record_id
			? auditHref(new URLSearchParams(), { resource: null, record_id: entry.record_id })
			: null
	);

	// O create já se explica pelo verbo ("Criou o agendamento") + o contexto; o diff cheio de
	// "— → valor" seria ruído. Só as ATUALIZAÇÕES mostram o antes/depois.
	const showDiff = $derived(entry.action_type !== 'create' && entry.diff.length > 0);

	const linkClass = 'inline-flex items-center gap-1 font-medium text-accent-text hover:underline';
</script>

<article class="flex gap-3 px-3.5 py-3">
	<span class="mt-0.5 shrink-0 {tone.klass}" aria-hidden="true">
		<tone.icon size={17} />
	</span>

	<div class="min-w-0 flex-1">
		<div class="flex items-baseline justify-between gap-3">
			<h3 class="min-w-0 text-corpo font-semibold leading-snug text-ink">{headline}</h3>
			<!--
				ACC-23 (doc 83): a linha mostra só a HORA, e a data completa vivia apenas no `title` —
				hover de mouse. Numa trilha de auditoria "14:32" sem dia não localiza nada, e o
				`datetime` não é lido por leitor de tela (é para máquina).

				Então o mesmo dado, duas formas: a curta para os olhos (`aria-hidden`, porque o texto ao
				lado já a cobre) e a completa em `sr-only`. O `title` fica para o mouse.
			-->
			<time
				class="shrink-0 whitespace-nowrap font-mono text-meta text-faint"
				datetime={entry.at}
				title={formatAt(entry.at, timezone)}
			>
				<span aria-hidden="true">{formatTime(entry.at, timezone)}</span>
				<span class="sr-only">{formatAt(entry.at, timezone)}</span>
			</time>
		</div>

		{#if context}
			<p class="mt-0.5 text-rotulo leading-snug text-muted">{context}</p>
		{/if}

		{#if showDiff}
			<FieldDiff resource={entry.resource} diff={entry.diff} {timezone} />
		{/if}

		<div class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-meta">
			<span class="text-faint">por {actorName}</span>
			<span class="flex-1"></span>
			{#if agendaHref}
				<a href={agendaHref} class={linkClass}>
					<CalendarSearch size={12} /> Ver na agenda
				</a>
			{/if}
			{#if historyHref}
				<a href={historyHref} class={linkClass}>
					<History size={12} /> Ver histórico
				</a>
			{/if}
		</div>
	</div>
</article>
