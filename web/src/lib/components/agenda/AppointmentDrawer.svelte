<script lang="ts">
	// O drawer do agendamento (protótipo `renderDrawer` :1800), Entrega 4 — ciclo de vida.
	//
	// Painel de 404px aberto ao selecionar um bloco. Mostra o estado, remarca (abre o modal) e
	// muda o status por AÇÕES NOMEADAS (concluir/faltar/cancelar/reabrir) — nunca um PATCH de
	// status (doc 25 §3). Cada mutação é um form com `use:enhance`: o resultado reexecuta o
	// load, o `appt` reflete o novo estado e o drawer segue aberto no mesmo id.
	//
	// A autoridade é a policy/máquina do servidor; o que mora aqui é espelho de UX (D-E4.1: o
	// gate de "começou" desabilita concluir/faltar; o servidor recusa de qualquer jeito).
	import { tick } from 'svelte';
	import { enhance } from '$app/forms';
	import ArrowRight from '@lucide/svelte/icons/arrow-right';
	import Send from '@lucide/svelte/icons/send';
	import Check from '@lucide/svelte/icons/check';
	import UserX from '@lucide/svelte/icons/user-x';
	import X from '@lucide/svelte/icons/x';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import RotateCcw from '@lucide/svelte/icons/rotate-ccw';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Sparkles from '@lucide/svelte/icons/sparkles';
	import Package from '@lucide/svelte/icons/package';
	import Clock from '@lucide/svelte/icons/clock';
	import Activity from '@lucide/svelte/icons/activity';
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import SwitchToggle from '$lib/components/scheduling/SwitchToggle.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import Drawer from '$lib/components/Drawer.svelte';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envio, envioPorItem } from '$lib/forms.svelte';
	import MessageTimeline from '$lib/components/agenda/MessageTimeline.svelte';
	import ConflictErrorBox from '$lib/components/agenda/ConflictErrorBox.svelte';
	import PriorityBadge from '$lib/components/fila/PriorityBadge.svelte';
	import { algumPodeReceber, type MessageParticipant } from '$lib/messages';
	import type { Entry } from '$lib/waitlist';
	import { formatarTelefone } from '$lib/telefone';
	import { avatarColor } from '$lib/avatar';
	import {
		statusSignal,
		shortDayLabel,
		todayInZone,
		attendanceSelo,
		statusActions,
		participantActions,
		packageDebit,
		resolvedCount,
		isTerminal,
		canExcludeAppointment,
		DRAWER_ACTIONS,
		canMutateAppointment,
		canCreateEncaixe,
		zonedParts,
		m2t,
		type Appointment,
		type Participant,
		type AgendaPatient,
		type AgendaProfessional,
		type AgendaAppointmentType
	} from '$lib/agenda';
	import type { Papel } from '$lib/session';

	let {
		appt,
		tipo = undefined,
		professional = undefined,
		patients = [],
		agora,
		timezone,
		papel,
		form = null,
		mensagens = null,
		candidatos = undefined,
		onClose,
		onReschedule,
		onToast
	}: {
		appt: Appointment;
		tipo?: AgendaAppointmentType;
		professional?: AgendaProfessional;
		patients?: AgendaPatient[];
		agora: string;
		timezone: string;
		papel: Papel | null;
		/** Resultado da última action (para o erro inline do 409/422). */
		form?: { action?: string; error?: string; code?: string } | null;
		/**
		 * A timeline de comunicação (doc 52 §6). `null` = ainda carregando; ela é buscada quando o
		 * drawer abre, não no load da agenda — ver `agenda/mensagens/[id]/+server.ts`.
		 */
		mensagens?: MessageParticipant[] | null;
		/**
		 * O "quem cabe aqui?" (AN-12, doc 64): os itens da fila que casam com a vaga que abriu.
		 * `undefined` = não se aplica (bloco sem vaga); `null` = consultando — buscado quando o
		 * drawer abre num bloco cancelado/faltou, ver `agenda/candidatos/+server.ts`.
		 */
		candidatos?: Entry[] | null;
		onClose: () => void;
		onReschedule: () => void;
		onToast: (msg: string) => void;
	} = $props();

	const podeMexer = $derived(canMutateAppointment(papel));

	// "0 falta(s)" é ruído — ninguém age sobre a ausência de falta — e a turma já o escondia
	// enquanto a sessão individual o mostrava: duas regras para o mesmo fato, na mesma tela.
	function plural(n: number, singular: string, muitos = `${singular}s`): string {
		return `${n} ${n === 1 ? singular : muitos}`;
	}

	const inicio = $derived(zonedParts(appt.starts_at, timezone));
	const fimMin = $derived(zonedParts(appt.ends_at, timezone).minutes);
	const dur = $derived(Math.round((Date.parse(appt.ends_at) - Date.parse(appt.starts_at)) / 60000));

	// O DIA entrou na linha do horário (doc 75, achado G). Ele existia só no cabeçalho da agenda,
	// atrás do drawer — e no celular o painel é `max-w-full` e cobre esse cabeçalho, então quem
	// abria um bloco pelo telefone não sabia de que dia ele era.
	//
	// Dia e faixa são DOIS pedaços porque têm pesos diferentes: o dia é contexto (miúdo, apagado),
	// a faixa é o fato (mono, cor de texto). Emendados numa string mono só, a linha estourava a
	// largura do painel e quebrava em duas — medido no browser, não estimado.
	const dia = $derived(shortDayLabel(inicio.date, todayInZone(agora, timezone)));
	const faixa = $derived(`${m2t(inicio.minutes)}–${m2t(fimMin)} (${dur}min)`);

	// D-H10: os dois campos são carimbados na conversão da fila, antes de a entry ser apagada — e
	// nenhuma tela os lia (doc 75, achado C). São o que fecha o ciclo: esta vaga foi coberta pela
	// fila, e o paciente esperou N dias por ela.
	const origem = $derived(
		appt.veio_da_fila
			? `Fila de espera${appt.dias_na_fila != null ? ` · esperou ${plural(appt.dias_na_fila, 'dia')}` : ''}`
			: null
	);

	const grupo = $derived(!!tipo?.grupo);

	// O chip do header sai da MESMA fonte do cartão (doc 75, achado A). Era `STATUS_META[status]`
	// cru: numa turma de 4 em que 1 veio e 3 faltaram, o cartão escreve "1 de 4 concluídas" (D13) e
	// o drawer que ele abre escrevia "Concluído" — duas verdades para o mesmo bloco, a 400px de
	// distância. E `STATUS_META` saiu do arquivo junto: era o último uso dele aqui.
	const sinal = $derived(statusSignal(appt, grupo));

	// O `null` do sinal é só o da turma mista (composição no lugar da palavra) — ali a cor é
	// neutra de propósito. Todo status de verdade traz o token dele.
	const tomDoStatus = $derived(sinal.tone ?? 'muted');

	const capacidade = $derived(tipo?.capacidade ?? 4);
	const porId = $derived(new Map(patients.map((p) => [p.id, p])));
	const participantes = $derived(appt.patient_ids.map((id) => porId.get(id)).filter(Boolean) as AgendaPatient[]);
	const soloPaciente = $derived(!grupo ? participantes[0] : undefined);

	// O título do painel segue a MESMA regra do cartão do grid (`AppointmentBlock`): na turma o
	// bloco é do tipo ("Pilates"); na individual, é da pessoa. Sem o paciente no sidecar (removido
	// entre a leitura e o render) sobra o rótulo neutro — nunca o nome do tipo, que faria um bloco
	// anônimo passar por identificado.
	const titulo = $derived(
		grupo ? (tipo?.nome ?? 'Turma') : (participantes[0]?.nome ?? 'Paciente')
	);

	// Quem atende, com o registro profissional. `crefito` já vem com o prefixo ("CREFITO 3/…"),
	// como o placeholder do cadastro escreve — daí não haver rótulo montado aqui.
	const legenda = $derived(
		professional
			? [professional.nome_exibicao ?? professional.nome, professional.crefito]
					.filter(Boolean)
					.join(' · ')
			: null
	);

	// A cor daquele profissional — a mesma da faixa lateral do bloco no grid. É o que liga o
	// painel à coluna de onde ele foi aberto.
	const corDoProfissional = $derived(
		professional ? avatarColor(professional.cor_indice) : 'var(--color-muted)'
	);

	// A2 (doc 41): a presença é por participante. A lista de status vem do `participants` do
	// bloco; a ORDEM segue `patient_ids`, para o drawer não reordenar sozinho a cada push do
	// tempo real.
	const presencas = $derived(new Map(appt.participants.map((p) => [p.patient_id, p])));
	const resolvidas = $derived(resolvedCount(appt.participants));
	const presencaSolo = $derived(soloPaciente ? presencas.get(soloPaciente.id) : undefined);

	// O form da presença é UM só, submetido com os campos preenchidos no clique (o mesmo padrão
	// do cancelar): N participantes × 4 verbos como forms separados seriam 4N forms no DOM.
	let presencaForm = $state<HTMLFormElement>();
	let presencaPatient = $state('');
	let presencaKind = $state('');
	let presencaJustificada = $state('false');
	let presencaMotivo = $state('');

	// Cada mutação daqui é um POST que leva o seu tempo, e quase nenhuma era idempotente: sem
	// sinal no botão, o segundo clique de quem achou que "não pegou" chega como 409 de versão.
	// Os forms escondidos são UM para as N linhas, então a chave do "em voo" só se conhece no
	// clique — daí o `submitDinamico` (ver `$lib/forms.svelte.ts`).
	const presencaEnvio = envioPorItem<string>();
	const filaEnvio = envioPorItem<string>();
	const confirmEnvio = envioPorItem<string>();
	const cancelEnvio = envio({
		aoResponder: () => {
			cancelando = false;
		}
	});
	const excluirEnvio = envio({
		aoResponder: () => {
			excluindo = false;
		}
	});
	const reabrirEnvio = envio();

	// O `await tick()` NÃO é cerimônia: sem ele o `requestSubmit()` roda no mesmo tick da
	// atribuição, o Svelte 5 ainda não escreveu os `value` dos inputs escondidos, e o form sai com
	// os campos VAZIOS — o servidor responde "Participante ou ação não informados" (400). Achado no
	// clique ao vivo: o teste de componente não pega, porque o `fireEvent` do testing-library já
	// devolve depois do flush.
	async function marcarPresenca(patientId: string, kind: string, justificada = false) {
		presencaPatient = patientId;
		presencaKind = kind;
		presencaJustificada = String(justificada);
		await tick();
		presencaForm?.requestSubmit();
	}

	// D-H3/D5 (doc 64): faltar passa a perguntar POR QUÊ — opcional, texto livre, e por
	// participante. Só a falta abre diálogo; concluir e reabrir seguem em um clique, porque não
	// há motivo a registrar em nenhum dos dois.
	//
	// Molde é o do cancelar, de propósito: mesmo `ConfirmDialog`, mesmo rótulo "(opcional)",
	// mesmo teto de 300. Duas conversas com a mesma cara para a mesma pergunta.
	let faltando = $state<{ patientId: string; nome: string } | null>(null);
	let motivoFalta = $state('');

	function abrirFalta(patientId: string, nome: string) {
		motivoFalta = '';
		faltando = { patientId, nome };
	}

	async function confirmarFalta() {
		const alvo = faltando;
		faltando = null;
		if (!alvo) return;
		presencaMotivo = motivoFalta;
		await marcarPresenca(alvo.patientId, 'no_show');
		presencaMotivo = '';
	}

	const ICON_PRESENCA = { Check, UserX, RotateCcw } as const;

	// Do trio do protótipo sobra o cancelar: concluir/faltar viraram presença por participante
	// (A2). Continua saindo de `statusActions` para o estado (`on`) ter fonte única.
	const cancelar = $derived(statusActions(appt, agora).find((a) => a.kind === 'cancelar'));
	const terminal = $derived(isTerminal(appt.status));

	// Excluir (soft-delete, doc 40) só o que não aconteceu — regra única em `$lib/agenda`. Um
	// cancelado (terminal, sem "Enviar confirmação") ainda pode ser excluído: é o caso mais comum
	// de "isso foi engano, some". Por isso o rodapé passa a existir por QUALQUER um dos dois botões,
	// não só por `!terminal`.
	const podeExcluir = $derived(canExcludeAppointment(appt.status));
	const mostraRodape = $derived(podeMexer && (!terminal || podeExcluir));

	// O "Enviar confirmação" do rodapé fica de pé mas **desabilitado** quando ninguém do bloco pode
	// receber agora. Desabilitado, e não escondido como o atalho da timeline: aquele é uma linha a
	// mais dentro da explicação (que já diz o motivo ao lado), este é a ação principal do drawer —
	// sumir com ela faria a recepção procurar o que não sumiu, apenas não pode agora. O porquê fica
	// no `title` e, por extenso, na seção Comunicação logo acima.
	const podeConfirmar = $derived(algumPodeReceber(mensagens));

	// O erro (409/422) só é do drawer quando a última action foi de ciclo de vida (fonte única
	// em `$lib/agenda`, não uma lista solta aqui).
	const erro = $derived(
		form && (DRAWER_ACTIONS as readonly string[]).includes(form.action ?? '') ? form.error : undefined
	);

	// Cancelar é a única ação de status que **pergunta** algo antes (F3). A coluna
	// `cancel_reason` sempre existiu e o drawer já a exibia depois do fato; o que faltava era
	// alguém para preenchê-la — cancelava-se em um clique e o motivo nascia sempre vazio.
	//
	// Vem com confirmação porque é destrutivo e sem desfazer imediato na mesma tela (reabrir
	// existe, mas é outro clique e outra linha de trilha). O motivo é **opcional**: exigi-lo
	// faria a recepção digitar qualquer coisa para conseguir cancelar, e "asdf" na trilha é
	// pior que vazio.
	let cancelando = $state(false);
	let motivo = $state('');
	let cancelForm = $state<HTMLFormElement>();

	function confirmarCancelamento() {
		cancelForm?.requestSubmit();
	}

	// Excluir também **pergunta** antes: é destrutivo e o desfazer só existe pela auditoria (não há
	// tela de "excluídos" na v1). O diálogo marca a diferença que o de cancelar faz ao contrário —
	// aqui o registro SOME da agenda e dos relatórios; se o atendimento existiu, o caminho é cancelar.
	let excluindo = $state(false);
	let excluirForm = $state<HTMLFormElement>();

	function confirmarExclusao() {
		excluirForm?.requestSubmit();
	}

	// "Quem cabe aqui?" (AN-12, doc 64 / D11). A seção só existe quando a vaga ABRIU — cancelado
	// ou faltou, os mesmos dois status que o motor de vagas trata como `freed` — e a lista vem da
	// página (buscada quando o drawer abre, como as mensagens). Agendar um candidato converte a
	// entry NA vaga do bloco: mesmo slot, mesmo tipo, mesma duração.
	//
	// A falta ocupa o horário para a exclusion constraint (`status <> 'cancelado'`), então cobrir
	// vaga de falta SÓ entra como encaixe — o form parte com o flag armado. No cancelado o flag só
	// arma pela saída do 422 (o horário foi tomado no meio-tempo), como no criar/remarcar.
	const vagaAberta = $derived(appt.status === 'cancelado' || appt.status === 'faltou');
	const precisaEncaixe = $derived(appt.status === 'faltou');
	const podeEncaixe = $derived(canCreateEncaixe(papel));

	let filaForm = $state<HTMLFormElement>();
	let filaEntryId = $state('');
	let filaEncaixe = $state(false);

	// Mesmo gotcha do `marcarPresenca`: sem o tick, o submit sai com o `id` VAZIO.
	async function agendarDaFila(entryId: string) {
		filaEntryId = entryId;
		await tick();
		filaForm?.requestSubmit();
	}

	const filaErro = $derived(form?.action === 'agendar_fila' ? form.error : undefined);
	const filaOfereceEncaixe = $derived(
		form?.action === 'agendar_fila' &&
			form?.code === 'schedule_conflict' &&
			podeEncaixe &&
			!precisaEncaixe &&
			!filaEncaixe
	);

	// Confirmação ao paciente (doc 52 §6). Um form só, com o participante preenchido no clique —
	// mesmo padrão do form de presença, e pelo mesmo motivo: numa turma de 4, quatro forms no DOM
	// para a mesma ação.
	//
	// O `await tick()` é o mesmo gotcha do `marcarPresenca`: sem ele o `requestSubmit()` roda antes
	// de o Svelte escrever o `value` do input escondido e o `patient_id` sai VAZIO — o que
	// dispararia para a turma inteira em vez de só para quem falhou.
	let confirmarForm = $state<HTMLFormElement>();
	let confirmarPatient = $state('');

	async function enviarConfirmacao(patientId = '') {
		confirmarPatient = patientId;
		await tick();
		confirmarForm?.requestSubmit();
	}
</script>

<!-- Rodapé (protótipo :1846): "Enviar confirmação" + o botão de excluir ao lado. Fica fora do
     `Drawer` e entra por prop porque quem não pode mexer não tem rodapé NENHUM — passar o
     snippet sempre renderia a faixa (borda + padding) vazia. Cada botão é condicional: enviar
     confirmação só faz sentido antes de terminar; excluir só o que não aconteceu (`podeExcluir`).
     Um cancelado tem só o excluir; um em atendimento, só o enviar. -->
{#snippet rodape()}
	<div class="flex items-center gap-2">
		{#if !terminal}
			<!-- Doc 52 / D-H4: era um `onToast('Confirmação enviada por WhatsApp')` que não enviava
			     nada. Agora submete de verdade; sem `patient_id`, vale para todos os participantes
			     que ainda podem receber. -->
			<SubmitButton
				type="button"
				onclick={() => enviarConfirmacao()}
				emVoo={confirmEnvio.emVoo('')}
				disabled={!podeConfirmar || confirmEnvio.algumEmVoo}
				title={podeConfirmar
					? undefined
					: 'Ninguém deste agendamento pode receber agora — o motivo está em Comunicação'}
				size={15}
				class="flex flex-1 items-center justify-center gap-2 rounded-lg border border-edge bg-surface px-3 py-2.5 text-[13px] font-semibold hover:bg-surface-2 disabled:cursor-not-allowed disabled:opacity-50 disabled:hover:bg-surface"
			>
				<Send size={15} /> Enviar confirmação
			</SubmitButton>
		{/if}

		{#if podeExcluir}
			<!-- Ícone só, e "fantasma" (só assume `danger` no hover/focus): destrutiva não senta ao
			     lado de uma benigna com o mesmo peso, senão vira erro de clique. Quando é o único
			     botão (cancelado), ocupa a linha. -->
			<button
				type="button"
				onclick={() => (excluindo = true)}
				aria-label="Excluir agendamento"
				title="Excluir — para lançamento feito por engano"
				class="flex h-10.5 items-center justify-center gap-2 rounded-lg border border-edge text-faint transition-colors hover:border-danger hover:text-danger focus-visible:border-danger focus-visible:text-danger {terminal
					? 'flex-1 text-[13px] font-semibold'
					: 'w-11 shrink-0'}"
			>
				<Trash2 size={15} />
				{#if terminal}Excluir{/if}
			</button>
		{/if}
	</div>
{/snippet}

<Drawer label="Detalhes do agendamento" {onClose} footer={mostraRodape ? rodape : undefined}>
	<!--
		Cabeçalho: QUEM antes de QUÊ (o X é do shell).

		Era só o chip de status — a informação mais consultada do painel (para quem é esta sessão?)
		vivia a 150px dali, dentro do cartão, com o mesmo peso do telefone. Agora o topo responde as
		duas perguntas de identificação: o **paciente** é o título e o **profissional com o
		registro** é a legenda; o ponto na frente é a cor daquele profissional, a mesma da faixa
		lateral do bloco no grid — é o que liga o painel à coluna de onde ele foi aberto.

		Na turma não existe "o paciente": o título é o TIPO, como no cartão do grid.

		O status desceu para o corpo, onde continua sendo a primeira coisa que se lê. Ele não é
		identificação, é estado — e estado muda (o painel fica aberto enquanto se marca presença).
	-->
	{#snippet header()}
		<span class="size-2 shrink-0 rounded-full" style="background:{corDoProfissional}"></span>
		<div class="min-w-0 flex-1">
			<div data-testid="drawer-titulo" class="truncate text-[14px] font-bold leading-tight">
				{titulo}
			</div>
			{#if legenda}
				<div data-testid="drawer-legenda" class="mt-0.5 truncate text-[11.5px] text-faint">
					{legenda}
				</div>
			{/if}
		</div>
	{/snippet}

	<div class="space-y-3.5 text-[13px]">
		<!-- O estado, agora no corpo. O ponto repete o tom do rótulo (é o mesmo par ponto+palavra
		     do cartão do grid) e o ENCAIXE fica ao lado, porque os dois qualificam a mesma coisa.

		     A cor é a do STATUS, não um cinza para tudo que não é verde/vermelho: cada um tem o seu
		     token (`muted` para agendado, `faint` para cancelado — ver `StatusMeta.tone`). O texto
		     usa a variante `-text` quando existe, porque o teal sólido não tem contraste sobre 14%
		     dele mesmo; sem a variante, cai no próprio token. É a mesma expressão do badge do
		     cartão — uma regra de cor, três superfícies. -->
		{#if !terminal || appt.encaixe}
			<div class="flex items-center gap-2">
				<!--
					E o chip se CALA quando o bloco já está resolvido. `Appointment.status` é rollup das
					presenças (A2/D13): num bloco terminal, "Cancelado"/"Concluído"/"Faltou" no topo é a
					mesma frase que o selo da presença diz logo abaixo, e a presença é a fonte — numa
					turma ela ainda diz por pessoa, o que o rollup nunca dirá.

					Enquanto NÃO há desfecho é o contrário: o participante fica calado (o selo só existe
					a partir de "Previsto") e a fase do bloco é a única coisa que responde "e aí, como
					está isso?". Daí o chip existir só aí.
				-->
				{#if !terminal}
					<span
						data-testid="drawer-status"
						class="inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[12px] font-semibold"
						style="background:color-mix(in srgb, var(--color-{tomDoStatus}) 14%, transparent);
						       color:var(--color-{tomDoStatus}-text, var(--color-{tomDoStatus}))"
					>
						<span class="size-1.5 rounded-full bg-current"></span>
						{sinal.label}
					</span>
				{/if}
				{#if appt.encaixe}
					<!-- O encaixe não é status: ele qualifica o bloco resolvido igual ao que ainda vai
					     acontecer, então sobrevive ao chip que sumiu.

					     AN-08: texto escuro FIXO sobre o âmbar (que é igual nos dois temas) — branco
					     ficava a 2,0:1 (o axe reprova); #161a1e dá 8,6:1. `text-ink` não serve: inverte
					     no escuro. -->
					<span class="rounded bg-warning-solid px-1.5 py-0.5 text-[10px] font-bold text-on-solid">ENCAIXE</span>
				{/if}
			</div>
		{/if}

		<!-- Horário, tipo e origem. Duas regras:

		     - os ícones não substituem o rótulo, acompanham: um relógio sozinho obriga a
		       decodificar, e o par ícone+palavra é a mesma regra do cartão (doc 64 §3);
		     - cada linha fecha com um divisor. Sem ele, rótulo apagado e valor escuro em linhas
		       consecutivas leem como uma tabela sem colunas — o traço é o que diz onde um fato
		       termina e o outro começa. Vale para a ÚLTIMA também: ela separa a ficha do bloco do
		       cartão do paciente, que vem logo abaixo com borda própria. -->
		<div>
			<div class="flex items-center gap-2 border-b border-edge py-2">
				<Clock size={14} class="shrink-0 text-faint" />
				<span class="w-14 shrink-0 text-faint">Horário</span>
				<span data-testid="drawer-horario" class="min-w-0 truncate">
					<span class="text-[12px] text-faint">{dia} ·</span>
					<span class="font-mono">{faixa}</span>
				</span>
			</div>
			<!-- Na turma o título JÁ é o tipo: repeti-lo aqui seria dizer o mesmo duas vezes em
			     150px de painel. -->
			{#if !grupo}
				<div class="flex items-center gap-2 border-b border-edge py-2">
					<Activity size={14} class="shrink-0 text-faint" />
					<span class="w-14 shrink-0 text-faint">Tipo</span>
					<span data-testid="drawer-tipo">{tipo?.nome ?? '—'}</span>
				</div>
			{/if}
			{#if origem}
				<div class="flex items-center gap-2 border-b border-edge py-2">
					<Sparkles size={14} class="shrink-0 text-faint" />
					<span class="w-14 shrink-0 text-faint">Origem</span>
					<span data-testid="drawer-origem">{origem}</span>
				</div>
			{/if}
		</div>

		<!-- Rotulada como os dois motivos logo abaixo (doc 75, achado D): três caixas cinzas
		     idênticas, e esta era a anônima — quem via não sabia o que estava lendo. -->
		{#if appt.obs}
			<div class="rounded-lg bg-surface-2 px-3 py-2 text-[12.5px] text-ink">
				<span class="font-semibold">Observação:</span>
				{appt.obs}
			</div>
		{/if}

		{#if appt.status === 'cancelado' && appt.cancel_reason}
			<div class="rounded-lg bg-surface-2 px-3 py-2 text-[12.5px] text-muted">
				<span class="font-semibold">Motivo do cancelamento:</span>
				{appt.cancel_reason}
			</div>
		{/if}

		<!-- O par do de cima. Sem status na condição de propósito: um bloco remarcado continua
		     `agendado`, e amarrar a exibição a um status esconderia o motivo justamente no estado
		     em que ele é a informação nova. Guarda o motivo da ÚLTIMA remarcação; as anteriores
		     estão na trilha. -->
		{#if appt.reschedule_reason}
			<div class="rounded-lg bg-surface-2 px-3 py-2 text-[12.5px] text-muted">
				<span class="font-semibold">Motivo da remarcação:</span>
				{appt.reschedule_reason}
			</div>
		{/if}

		<!-- Presença POR PARTICIPANTE (A2, doc 41). Substitui, na tela, o concluir/faltar do bloco:
		     numa turma de quatro, um pode ter vindo e outro não, e o desfecho do bloco é o ROLLUP
		     disso (quem escreve o status do bloco é o servidor). Vale igual para sessão individual —
		     marca-se a única presença. -->
		{#snippet controlesPresenca(p: AgendaPatient, presenca: Participant)}
			{@const acoes = participantActions(presenca, appt, agora)}
			<!-- O motivo da falta, depois do fato. Ele era coletado no diálogo e nunca mais aparecia
			     — o irmão `cancel_reason` é exibido desde a Frente 4, e registrar sem poder consultar
			     é a metade inútil da dupla: quem pergunta "por que a clínica perde sessão" precisa
			     ler, não escrever. Fica por participante, como o campo. -->
			{#if presenca.status === 'faltou' && presenca.motivo}
				<div class="mt-1 text-[11.5px] text-muted">
					<span class="font-semibold">Motivo:</span>
					{presenca.motivo}
				</div>
			{/if}
			{#if podeMexer && acoes.length > 0}
				<div class="mt-1.5 flex flex-wrap items-center gap-1.5">
					{#each acoes as ac (ac.kind)}
						{@const Icon = ICON_PRESENCA[ac.icon as keyof typeof ICON_PRESENCA]}
						<SubmitButton
							type="button"
							onclick={() =>
								ac.kind === 'no_show' ? abrirFalta(p.id, p.nome) : marcarPresenca(p.id, ac.kind)}
							emVoo={presencaEnvio.emVoo(`${p.id}:${ac.kind}`)}
							disabled={ac.disabled || presencaEnvio.algumEmVoo}
							title={ac.title}
							size={13}
							class="flex items-center gap-1.5 rounded-lg border border-edge px-2 py-1.5 text-[12px] font-semibold transition-colors hover:bg-surface-2 disabled:cursor-not-allowed disabled:opacity-55"
						>
							<Icon size={13} />
							{ac.label}
						</SubmitButton>
					{/each}

					{#if presenca.status === 'faltou'}
						<!-- Justificar é da PRESENÇA, não do bloco: numa turma, a falta de um pode ser
						     justificada e a do outro não — e é isso que decide o débito de cada pacote. -->
						<label class="ml-auto flex items-center gap-2 text-[11.5px] text-faint">
							<span>Justificada</span>
							<SwitchToggle
								checked={presenca.falta_justificada}
								label="Justificar falta de {p.nome}"
								onchange={() => marcarPresenca(p.id, 'justify', !presenca.falta_justificada)}
							/>
						</label>
					{/if}
				</div>
			{/if}
		{/snippet}

		<!--
		A sessão de pacote, DENTRO do participante — e não numa seção do bloco. O pacote é por
		presença (D11): numa turma de quatro, dois podem estar em pacotes diferentes e um terceiro
		ser particular. Uma caixa por participante é a única forma que não mente. (No protótipo era
		uma seção só do bloco, [`:1879`], porque lá o vínculo vivia num mapa `pkgOf` do agendamento.)

		Responde três coisas, nesta ordem: **qual** pacote, **que sessão** desta série, e **quanto
		sobra** — a última é a que muda o que a recepção faz a seguir, por isso é ela que leva à ficha.
	-->
	{#snippet pacoteDaPresenca(presenca: Participant, patientId: string)}
		{#if presenca.package}
			{@const pkg = presenca.package}
			{@const debito = packageDebit(presenca)}
			<div data-testid="drawer-pacote" class="mt-1.5">
				<!--
					Sem caixa, sem preenchimento e sem borda: a primeira versão era um retângulo teal
					com três linhas dentro, e num painel que já tem cartão de paciente, botões de
					presença e timeline, ele gritava mais alto que o próprio paciente. Do verde sobra
					o ícone de 13px — o suficiente para dizer "pacote" sem disputar a atenção.

					O saldo ("7 restantes") saiu junto: quantas sobram é pergunta da FICHA, e a caixa
					dizia três coisas onde cabiam duas. O campo saiu do contrato atrás dela.

					O link é a linha inteira — o mesmo destino de antes, sem gastar uma linha própria.
				-->
				<a
					href="/pacientes/{patientId}#pacotes"
					title="Pacote {pkg.nome}{pkg.sessao
						? ` · sessão ${pkg.sessao} de ${pkg.total}`
						: ''} — ver na ficha"
					class="flex items-center gap-1.5 text-[12.5px] hover:underline"
				>
					<Package size={13} class="shrink-0 text-teal-text" />
					<span class="truncate font-medium">{pkg.nome}</span>
					{#if pkg.sessao}
						<span class="shrink-0 text-muted">· {pkg.sessao} de {pkg.total}</span>
					{/if}
				</a>

				{#if debito}
					<!-- Antes do desfecho isto é PREVISÃO (tom neutro, sem ícone): "faltar hoje consome
					     uma das 10" é o que muda a conversa com o paciente antes da falta. Depois, vira
					     fato — e ganha ícone, porque aí é consequência, não aviso. -->
					<div
						class="mt-0.5 flex items-center gap-1.5 text-[11.5px] {debito.tone === 'danger'
							? 'text-danger'
							: debito.tone === 'success'
								? 'text-success'
								: 'text-faint'}"
					>
						{#if debito.tone === 'danger'}
							<TriangleAlert size={12} class="shrink-0" />
						{:else if debito.tone === 'success'}
							<ShieldCheck size={12} class="shrink-0" />
						{/if}
						{debito.label}
					</div>
				{/if}
			</div>
		{/if}
	{/snippet}

	{#snippet selo(presenca: Participant)}
			{@const attMeta = attendanceSelo(presenca.status, presenca.falta_justificada)}
			{#if presenca.status !== 'prevista'}
				<span
					class="rounded-full px-2 py-0.5 text-[11px] font-semibold"
					style="background:{attMeta.tone
						? `color-mix(in srgb, var(--color-${attMeta.tone}) 14%, transparent)`
						: 'var(--color-surface-2)'}; color:{attMeta.tone
						? `var(--color-${attMeta.tone})`
						: 'var(--color-muted)'}"
				>
					{attMeta.label}
				</span>
			{/if}
		{/snippet}

		<!-- O form é um só para as N linhas × 4 verbos (o mesmo padrão do cancelar): os campos são
		     preenchidos no clique e submetidos. `expected_version` é a do BLOCO — a versão vive lá,
		     e o 409 continua sendo o mesmo guard do resto da agenda. -->
		<form
			method="POST"
			action="?/presenca"
			use:enhance={presencaEnvio.submitDinamico(() => `${presencaPatient}:${presencaKind}`)}
			bind:this={presencaForm}
			class="hidden"
		>
			<input type="hidden" name="id" value={appt.id} />
			<input type="hidden" name="expected_version" value={appt.version} />
			<input type="hidden" name="patient_id" value={presencaPatient} />
			<input type="hidden" name="kind" value={presencaKind} />
			<input type="hidden" name="justificada" value={presencaJustificada} />
			<input type="hidden" name="motivo" value={presencaMotivo} />
		</form>

		<!-- Paciente(s) -->
		{#if grupo}
			<div class="rounded-lg border border-edge">
				<div class="flex items-center justify-between border-b border-edge px-3 py-2 text-[12px] text-faint">
					<span>Pacientes na turma</span>
					<span class="font-mono">
						{participantes.length}/{capacidade}
						{#if resolvidas > 0}· {resolvidas} resolvida(s){/if}
					</span>
				</div>
				<ul class="divide-y divide-edge">
					{#each participantes as p (p.id)}
						{@const presenca = presencas.get(p.id)}
						<li class="px-3 py-2">
							<div class="flex items-center gap-2">
								<span class="truncate">{p.nome}</span>
								{#if presenca}{@render selo(presenca)}{/if}
								{#if p.faltas}<span class="ml-auto text-[11px] text-faint">{plural(p.faltas, 'falta')}</span>{/if}
							</div>
							{#if presenca}{@render pacoteDaPresenca(presenca, p.id)}{/if}
							{#if presenca}{@render controlesPresenca(p, presenca)}{/if}
						</li>
					{/each}
				</ul>
			</div>
		{:else if soloPaciente}
			<div class="rounded-lg border border-edge px-3 py-2.5">
				<!-- O NOME não se repete aqui: ele é o título do painel desde que o cabeçalho passou a
				     responder "para quem é esta sessão". Sobra o que o título não diz — contato,
				     faltas, pacote — e o selo da presença, que sobe para esta linha. Na TURMA o nome
				     fica, porque ali ele identifica de quem é cada presença, não o bloco. -->
				<div class="flex items-center gap-2 text-[12px] text-faint">
					<!-- O drawer é a tela de onde a recepção LIGA (doc 75, achado E); era um `<span>`
					     morto. E a contagem de faltas segue a regra da turma: zero não aparece. -->
					{#if soloPaciente.tel}
						<a href="tel:{soloPaciente.tel}" class="font-mono hover:underline">
							{formatarTelefone(soloPaciente.tel)}
						</a>
					{/if}
					{#if soloPaciente.faltas}<span>· {plural(soloPaciente.faltas, 'falta')}</span>{/if}
					{#if presencaSolo}
						<span class="ml-auto shrink-0">{@render selo(presencaSolo)}</span>
					{/if}
				</div>
				{#if presencaSolo}{@render pacoteDaPresenca(presencaSolo, soloPaciente.id)}{/if}
				{#if presencaSolo}{@render controlesPresenca(soloPaciente, presencaSolo)}{/if}
				<a
					href="/pacientes/{soloPaciente.id}"
					class="mt-2 inline-flex items-center gap-1 text-[12.5px] font-semibold text-teal-text hover:underline"
				>
					Abrir ficha <ArrowRight size={13} />
				</a>
			</div>
		{/if}

		<!-- "Quem cabe aqui?" (AN-12, doc 64 / HOM-018): a vaga que abriu pergunta à fila. Só
		     existe quando o bloco é cancelado/faltou E a página buscou (`candidatos` ausente =
		     bloco sem vaga). Agendar converte a entry NA vaga — mesmo slot, tipo e duração. -->
		{#if vagaAberta && candidatos !== undefined}
			<div class="rounded-lg border border-edge">
				<div class="flex items-center gap-1.5 border-b border-edge px-3 py-2 text-[12px] text-faint">
					<Sparkles size={13} class="shrink-0 text-teal-text" />
					<span class="font-semibold text-muted">Quem cabe aqui</span>
					<a href="/fila" class="ml-auto inline-flex items-center gap-1 font-semibold text-teal-text hover:underline">
						Ver fila <ArrowRight size={12} />
					</a>
				</div>

				{#if candidatos === null}
					<div class="px-3 py-3 text-[12.5px] text-faint">Consultando a fila…</div>
				{:else if candidatos.length === 0}
					<div class="px-3 py-3 text-[12.5px] text-faint">
						Ninguém na fila casa com este horário.
					</div>
				{:else}
					<ul class="divide-y divide-edge">
						{#each candidatos as c (c.id)}
							<li class="flex items-center gap-2 px-3 py-2">
								<div class="min-w-0 flex-1">
									<div class="flex items-center gap-2">
										<span class="truncate text-[13px]">{c.patient.nome}</span>
										<PriorityBadge prio={c.prio} />
									</div>
									<div class="mt-0.5 text-[11.5px] text-faint">{c.dias_na_fila} dia(s) na fila</div>
								</div>
								{#if podeMexer}
									<SubmitButton
										type="button"
										onclick={() => agendarDaFila(c.id)}
										emVoo={filaEnvio.emVoo(c.id)}
										disabled={(precisaEncaixe && !podeEncaixe) || filaEnvio.algumEmVoo}
										title={precisaEncaixe
											? 'A vaga é de uma falta — o novo agendamento entra como encaixe'
											: `Agendar ${c.patient.nome} neste horário`}
										size={13}
										class="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-teal-border bg-teal-subtle px-2.5 py-1.5 text-[12px] font-semibold text-teal-text transition-colors hover:bg-teal hover:text-white disabled:cursor-not-allowed disabled:opacity-55"
									>
										Agendar
									</SubmitButton>
								{/if}
							</li>
						{/each}
					</ul>
				{/if}

				{#if filaErro}
					<div class="px-3 pb-2.5">
						<ConflictErrorBox
							erro={filaErro}
							ofereceEncaixe={filaOfereceEncaixe}
							onEncaixe={() => (filaEncaixe = true)}
						/>
					</div>
				{/if}
			</div>

			<!-- Um form só para as N linhas (padrão do form de presença): o `id` da entry entra no
			     clique; o slot é o do BLOCO. Sem `expected_version`: a conversão cria um agendamento
			     novo, não disputa a versão deste. -->
			<form
				method="POST"
				action="?/agendar_fila"
				use:enhance={filaEnvio.submitDinamico(() => filaEntryId)}
				bind:this={filaForm}
				class="hidden"
			>
				<input type="hidden" name="id" value={filaEntryId} />
				<input type="hidden" name="starts_at" value={appt.starts_at} />
				<input type="hidden" name="professional_id" value={appt.professional_id} />
				<input type="hidden" name="appointment_type_id" value={appt.appointment_type_id} />
				<input type="hidden" name="duration_minutos" value={dur} />
				<input type="hidden" name="encaixe" value={String(precisaEncaixe || filaEncaixe)} />
			</form>
		{/if}

		{#if erro}
			<div
				class="flex items-start gap-2 rounded-lg px-3 py-2.5 text-[12.5px]"
				style="background:color-mix(in srgb, var(--color-danger) 10%, transparent); color:var(--color-danger)"
			>
				<TriangleAlert size={16} class="mt-0.5 shrink-0" />
				<div>{erro}</div>
			</div>
		{/if}

		{#if podeMexer}
			<!-- Remarcar -->
			<button
				type="button"
				onclick={onReschedule}
				disabled={appt.status === 'cancelado'}
				class="flex w-full items-center justify-center gap-2 rounded-lg border border-edge bg-surface px-3 py-2.5 text-[13px] font-semibold hover:bg-surface-2 disabled:cursor-not-allowed disabled:opacity-50"
			>
				<CalendarClock size={15} /> Remarcar sessão
			</button>

			<!-- Cancelar a sessão. Concluir/faltar saíram daqui na A2 (doc 41): o desfecho do bloco
			     deixou de ser um clique e virou o rollup das presenças acima. Cancelar fica porque é
			     fase de AGENDAMENTO (a sessão não vai acontecer), não desfecho — e continua sendo
			     escrita no bloco. Não submete direto: abre a confirmação, que pergunta o motivo (F3). -->
			<!--
				Duas mudanças de PESO (doc 75, achado F), nenhuma de comportamento:

				 1. o botão some quando o bloco já está cancelado. Ele ficava desabilitado escrevendo
				    "Cancelado" — repetindo o chip do header e ocupando a linha onde o "Reabrir"
				    aparece. Um controle que só sabe dizer o que o header já disse não é controle;
				 2. deixou de ter o mesmo peso do "Remarcar". Eram dois botões de largura total,
				    idênticos, dizendo que remarcar e cancelar são a mesma classe de coisa. Agora é
				    fantasma — só assume `danger` no hover/focus —, exatamente o tratamento que o
				    Excluir do rodapé já usa por ser destrutivo.
			-->
			{#if cancelar && !cancelar.on}
				<button
					type="button"
					onclick={() => (cancelando = true)}
					class="flex w-full items-center justify-center gap-1.5 rounded-lg border border-edge px-2 py-2 text-[12.5px] font-semibold text-muted transition-colors hover:border-danger hover:text-danger focus-visible:border-danger focus-visible:text-danger"
				>
					<X size={14} /> Cancelar sessão
				</button>
			{/if}

			<!-- Fora do laço porque é submetido de fora dele (pela confirmação), e porque leva um
			     campo que nenhuma outra ação tem. -->
			<form
				method="POST"
				action="?/cancelar"
				use:enhance={cancelEnvio.submit}
				bind:this={cancelForm}
				class="hidden"
			>
				<input type="hidden" name="id" value={appt.id} />
				<input type="hidden" name="expected_version" value={appt.version} />
				<input type="hidden" name="cancel_reason" value={motivo} />
			</form>

			<!-- Excluir (doc 40): submetido pela confirmação do rodapé. Fica aqui, sob `podeMexer`,
			     como o de cancelar — o botão que o dispara mora no rodapé, mas o form é o mesmo id +
			     versão de sempre. -->
			<form
				method="POST"
				action="?/excluir"
				use:enhance={excluirEnvio.submit}
				bind:this={excluirForm}
				class="hidden"
			>
				<input type="hidden" name="id" value={appt.id} />
				<input type="hidden" name="expected_version" value={appt.version} />
			</form>

			<!-- Confirmação ao paciente (doc 52 §6). Submetido pelo rodapé (todos) ou pelo
			     "Reenviar" de uma linha da timeline (um participante). Sem `expected_version`: mandar
			     mensagem não muda o bloco, então não disputa a versão dele. -->
			<form
				method="POST"
				action="?/confirmar"
				use:enhance={confirmEnvio.submitDinamico(() => confirmarPatient)}
				bind:this={confirmarForm}
				class="hidden"
			>
				<input type="hidden" name="id" value={appt.id} />
				<input type="hidden" name="patient_id" value={confirmarPatient} />
			</form>

			{#if terminal}
				<!-- Reabrir → agendado (D-E4.2): desfaz um clique errado. -->
				<form method="POST" action="?/reabrir" use:enhance={reabrirEnvio.submit}>
					<input type="hidden" name="id" value={appt.id} />
					<input type="hidden" name="expected_version" value={appt.version} />
					<SubmitButton
						emVoo={reabrirEnvio.emVoo}
						size={15}
						class="flex w-full items-center justify-center gap-2 rounded-lg border border-edge bg-surface px-3 py-2.5 text-[13px] font-semibold hover:bg-surface-2 disabled:opacity-60"
					>
						<RotateCcw size={15} /> Reabrir agendamento
					</SubmitButton>
				</form>
			{/if}
		{/if}
	</div>

	<!-- A timeline fecha o corpo do drawer: é histórico, não ação — quem abre o bloco quer ver o
	     estado dele primeiro. Fica FORA do `podeMexer` porque ler o que já saiu não é escrita. -->
	<MessageTimeline
		participantes={mensagens ?? []}
		carregando={mensagens === null}
		{timezone}
		{agora}
		podeEnviar={podeMexer && !terminal}
		onReenviar={(patientId) => enviarConfirmacao(patientId)}
	/>
</Drawer>

{#if cancelando}
	<ConfirmDialog
		title="Cancelar agendamento"
		confirmLabel="Cancelar agendamento"
		cancelLabel="Voltar"
		submitting={cancelEnvio.emVoo}
		onConfirm={confirmarCancelamento}
		onClose={() => (cancelando = false)}
	>
		O bloco fica registrado como <strong>cancelado</strong> — nada é apagado. Reabrir depois é
		possível, mas as duas ações ficam na trilha.

		<label class="mt-3 block">
			<span class="mb-1 block text-[12px] font-semibold text-muted">Motivo (opcional)</span>
			<input
				type="text"
				bind:value={motivo}
				maxlength="300"
				placeholder="Ex.: paciente pediu, imprevisto do profissional…"
				class="w-full rounded-md border border-edge bg-surface px-2.5 py-2 text-[13px] text-ink placeholder:text-faint focus:border-teal focus:outline-none"
			/>
		</label>
	</ConfirmDialog>
{/if}

{#if faltando}
	<!-- D-H3/D5: a falta pergunta o motivo. Mesmo diálogo do cancelar, e a razão de ser o mesmo é
	     a pergunta ser a mesma — mudar a cara confundiria duas conversas idênticas.
	     O nome do participante está no título porque numa turma este diálogo abre quatro vezes,
	     uma por pessoa, e sem o nome a recepção não sabe de quem é a falta que está registrando. -->
	<ConfirmDialog
		title="Registrar falta de {faltando.nome}"
		confirmLabel="Registrar falta"
		cancelLabel="Voltar"
		submitting={presencaEnvio.algumEmVoo}
		onConfirm={confirmarFalta}
		onClose={() => (faltando = null)}
	>
		A falta fica registrada <strong>só para {faltando.nome}</strong> — os outros participantes
		não são afetados. Justificar depois é o que a faz parar de contar.

		<label class="mt-3 block">
			<span class="mb-1 block text-[12px] font-semibold text-muted">Motivo (opcional)</span>
			<input
				type="text"
				bind:value={motivoFalta}
				maxlength="300"
				placeholder="Ex.: avisou que estava doente, não avisou…"
				class="w-full rounded-md border border-edge bg-surface px-2.5 py-2 text-[13px] text-ink placeholder:text-faint focus:border-teal focus:outline-none"
			/>
		</label>
	</ConfirmDialog>
{/if}

{#if excluindo}
	<!-- O contraponto do diálogo de cancelar: aqui o registro SOME, e a diferença tem de estar
	     escrita para a recepção não usar um no lugar do outro. -->
	<ConfirmDialog
		title="Excluir agendamento"
		confirmLabel="Excluir agendamento"
		cancelLabel="Voltar"
		submitting={excluirEnvio.emVoo}
		onConfirm={confirmarExclusao}
		onClose={() => (excluindo = false)}
	>
		O bloco <strong>some</strong> da agenda e dos relatórios. Isto é para lançamento feito por
		engano — se o atendimento existiu e não vai acontecer, use <strong>Cancelar</strong>.
	</ConfirmDialog>
{/if}
