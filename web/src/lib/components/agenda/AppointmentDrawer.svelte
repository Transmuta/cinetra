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
	import SwitchToggle from '$lib/components/scheduling/SwitchToggle.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import Drawer from '$lib/components/Drawer.svelte';
	import {
		STATUS_META,
		attendanceSelo,
		statusActions,
		participantActions,
		resolvedCount,
		isTerminal,
		canExcludeAppointment,
		DRAWER_ACTIONS,
		canMutateAppointment,
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
		onClose: () => void;
		onReschedule: () => void;
		onToast: (msg: string) => void;
	} = $props();

	const meta = $derived(STATUS_META[appt.status]);
	const podeMexer = $derived(canMutateAppointment(papel));

	const iniMin = $derived(zonedParts(appt.starts_at, timezone).minutes);
	const fimMin = $derived(zonedParts(appt.ends_at, timezone).minutes);
	const dur = $derived(Math.round((Date.parse(appt.ends_at) - Date.parse(appt.starts_at)) / 60000));
	const horario = $derived(`${m2t(iniMin)}–${m2t(fimMin)} (${dur}min)`);

	const grupo = $derived(!!tipo?.grupo);
	const capacidade = $derived(tipo?.capacidade ?? 4);
	const porId = $derived(new Map(patients.map((p) => [p.id, p])));
	const participantes = $derived(appt.patient_ids.map((id) => porId.get(id)).filter(Boolean) as AgendaPatient[]);
	const soloPaciente = $derived(!grupo ? participantes[0] : undefined);

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
		cancelando = false;
		cancelForm?.requestSubmit();
	}

	// Excluir também **pergunta** antes: é destrutivo e o desfazer só existe pela auditoria (não há
	// tela de "excluídos" na v1). O diálogo marca a diferença que o de cancelar faz ao contrário —
	// aqui o registro SOME da agenda e dos relatórios; se o atendimento existiu, o caminho é cancelar.
	let excluindo = $state(false);
	let excluirForm = $state<HTMLFormElement>();

	function confirmarExclusao() {
		excluindo = false;
		excluirForm?.requestSubmit();
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
			<button
				type="button"
				onclick={() => onToast('Confirmação enviada por WhatsApp')}
				class="flex flex-1 items-center justify-center gap-2 rounded-lg border border-edge bg-surface px-3 py-2.5 text-[13px] font-semibold hover:bg-surface-2"
			>
				<Send size={15} /> Enviar confirmação
			</button>
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
	<!-- Cabeçalho: status + encaixe (o X é do shell). -->
	{#snippet header()}
		<span
			class="rounded-full px-2.5 py-1 text-[12px] font-semibold"
			style="background:{meta.tone
				? `color-mix(in srgb, var(--color-${meta.tone}) 14%, transparent)`
				: 'var(--color-surface-2)'}; color:{meta.tone ? `var(--color-${meta.tone})` : 'var(--color-muted)'}"
		>
			{meta.label}
		</span>
		{#if appt.encaixe}
			<span class="rounded bg-warning px-1.5 py-0.5 text-[10px] font-bold text-white">ENCAIXE</span>
		{/if}
	{/snippet}

	<div class="space-y-3.5 text-[13px]">
		<!-- Horário e tipo -->
		<div class="space-y-1.5">
			<div class="flex items-baseline gap-2">
				<span class="w-16 shrink-0 text-faint">Horário</span>
				<span class="font-mono">{horario}</span>
			</div>
			<div class="flex items-baseline gap-2">
				<span class="w-16 shrink-0 text-faint">Tipo</span>
				<span>{tipo?.nome ?? '—'}{professional ? ` · ${professional.nome_exibicao ?? professional.nome}` : ''}</span>
			</div>
		</div>

		{#if appt.obs}
			<div class="rounded-lg bg-surface-2 px-3 py-2 text-[12.5px] text-ink">{appt.obs}</div>
		{/if}

		{#if appt.status === 'cancelado' && appt.cancel_reason}
			<div class="rounded-lg bg-surface-2 px-3 py-2 text-[12.5px] text-muted">
				<span class="font-semibold">Motivo do cancelamento:</span>
				{appt.cancel_reason}
			</div>
		{/if}

		<!-- Presença POR PARTICIPANTE (A2, doc 41). Substitui, na tela, o concluir/faltar do bloco:
		     numa turma de quatro, um pode ter vindo e outro não, e o desfecho do bloco é o ROLLUP
		     disso (quem escreve o status do bloco é o servidor). Vale igual para sessão individual —
		     marca-se a única presença. -->
		{#snippet controlesPresenca(p: AgendaPatient, presenca: Participant)}
			{@const acoes = participantActions(presenca, appt, agora)}
			{#if podeMexer && acoes.length > 0}
				<div class="mt-1.5 flex flex-wrap items-center gap-1.5">
					{#each acoes as ac (ac.kind)}
						{@const Icon = ICON_PRESENCA[ac.icon as keyof typeof ICON_PRESENCA]}
						<button
							type="button"
							onclick={() => marcarPresenca(p.id, ac.kind)}
							disabled={ac.disabled}
							title={ac.title}
							class="flex items-center gap-1.5 rounded-lg border border-edge px-2 py-1.5 text-[12px] font-semibold transition-colors hover:bg-surface-2 disabled:cursor-not-allowed disabled:opacity-55"
						>
							<Icon size={13} />
							{ac.label}
						</button>
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
		<form method="POST" action="?/presenca" use:enhance bind:this={presencaForm} class="hidden">
			<input type="hidden" name="id" value={appt.id} />
			<input type="hidden" name="expected_version" value={appt.version} />
			<input type="hidden" name="patient_id" value={presencaPatient} />
			<input type="hidden" name="kind" value={presencaKind} />
			<input type="hidden" name="justificada" value={presencaJustificada} />
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
								{#if p.faltas}<span class="ml-auto text-[11px] text-faint">{p.faltas} falta(s)</span>{/if}
							</div>
							{#if presenca}{@render controlesPresenca(p, presenca)}{/if}
						</li>
					{/each}
				</ul>
			</div>
		{:else if soloPaciente}
			<div class="rounded-lg border border-edge px-3 py-2.5">
				<div class="flex items-center gap-2">
					<div class="font-semibold">{soloPaciente.nome}</div>
					{#if presencaSolo}{@render selo(presencaSolo)}{/if}
				</div>
				<div class="mt-0.5 flex items-center gap-2 text-[12px] text-faint">
					{#if soloPaciente.tel}<span class="font-mono">{soloPaciente.tel}</span>{/if}
					{#if soloPaciente.faltas != null}<span>· {soloPaciente.faltas} falta(s)</span>{/if}
				</div>
				{#if presencaSolo}{@render controlesPresenca(soloPaciente, presencaSolo)}{/if}
				<a
					href="/pacientes/{soloPaciente.id}"
					class="mt-2 inline-flex items-center gap-1 text-[12.5px] font-semibold text-teal-text hover:underline"
				>
					Abrir ficha <ArrowRight size={13} />
				</a>
			</div>
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
			{#if cancelar}
				<button
					type="button"
					onclick={() => (cancelando = true)}
					disabled={cancelar.on}
					class="flex w-full items-center justify-center gap-1.5 rounded-lg border px-2 py-2.5 text-[12.5px] font-semibold transition-colors disabled:cursor-not-allowed
					{cancelar.on ? 'border-current text-ink' : 'border-edge hover:bg-surface-2'}"
					style={cancelar.on && STATUS_META[cancelar.status].tone
						? `color:var(--color-${STATUS_META[cancelar.status].tone}); background:color-mix(in srgb, var(--color-${STATUS_META[cancelar.status].tone}) 10%, transparent)`
						: ''}
				>
					<X size={14} />
					{cancelar.on ? 'Cancelado' : 'Cancelar sessão'}
				</button>
			{/if}

			<!-- Fora do laço porque é submetido de fora dele (pela confirmação), e porque leva um
			     campo que nenhuma outra ação tem. -->
			<form method="POST" action="?/cancelar" use:enhance bind:this={cancelForm} class="hidden">
				<input type="hidden" name="id" value={appt.id} />
				<input type="hidden" name="expected_version" value={appt.version} />
				<input type="hidden" name="cancel_reason" value={motivo} />
			</form>

			<!-- Excluir (doc 40): submetido pela confirmação do rodapé. Fica aqui, sob `podeMexer`,
			     como o de cancelar — o botão que o dispara mora no rodapé, mas o form é o mesmo id +
			     versão de sempre. -->
			<form method="POST" action="?/excluir" use:enhance bind:this={excluirForm} class="hidden">
				<input type="hidden" name="id" value={appt.id} />
				<input type="hidden" name="expected_version" value={appt.version} />
			</form>

			{#if terminal}
				<!-- Reabrir → agendado (D-E4.2): desfaz um clique errado. -->
				<form method="POST" action="?/reabrir" use:enhance>
					<input type="hidden" name="id" value={appt.id} />
					<input type="hidden" name="expected_version" value={appt.version} />
					<button
						type="submit"
						class="flex w-full items-center justify-center gap-2 rounded-lg border border-edge bg-surface px-3 py-2.5 text-[13px] font-semibold hover:bg-surface-2"
					>
						<RotateCcw size={15} /> Reabrir agendamento
					</button>
				</form>
			{/if}
		{/if}
	</div>
</Drawer>

{#if cancelando}
	<ConfirmDialog
		title="Cancelar agendamento"
		confirmLabel="Cancelar agendamento"
		cancelLabel="Voltar"
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

{#if excluindo}
	<!-- O contraponto do diálogo de cancelar: aqui o registro SOME, e a diferença tem de estar
	     escrita para a recepção não usar um no lugar do outro. -->
	<ConfirmDialog
		title="Excluir agendamento"
		confirmLabel="Excluir agendamento"
		cancelLabel="Voltar"
		onConfirm={confirmarExclusao}
		onClose={() => (excluindo = false)}
	>
		O bloco <strong>some</strong> da agenda e dos relatórios. Isto é para lançamento feito por
		engano — se o atendimento existiu e não vai acontecer, use <strong>Cancelar</strong>.
	</ConfirmDialog>
{/if}
