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
	import { enhance } from '$app/forms';
	import ArrowRight from '@lucide/svelte/icons/arrow-right';
	import Send from '@lucide/svelte/icons/send';
	import Check from '@lucide/svelte/icons/check';
	import UserX from '@lucide/svelte/icons/user-x';
	import X from '@lucide/svelte/icons/x';
	import RotateCcw from '@lucide/svelte/icons/rotate-ccw';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import SwitchToggle from '$lib/components/scheduling/SwitchToggle.svelte';
	import {
		STATUS_META,
		statusActions,
		isTerminal,
		DRAWER_ACTIONS,
		canMutateAppointment,
		zonedParts,
		m2t,
		type Appointment,
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

	const acoes = $derived(statusActions(appt, agora));
	const terminal = $derived(isTerminal(appt.status));
	const faltou = $derived(appt.status === 'faltou');

	// Ícone por ação — o `statusActions` devolve o NOME (evita importar Lucide na regra pura).
	const ICON = { Check, UserX, X } as const;

	// O erro (409/422) só é do drawer quando a última action foi de ciclo de vida (fonte única
	// em `$lib/agenda`, não uma lista solta aqui).
	const erro = $derived(
		form && (DRAWER_ACTIONS as readonly string[]).includes(form.action ?? '') ? form.error : undefined
	);

	let justifyForm = $state<HTMLFormElement>();
</script>

<aside
	class="fixed inset-y-0 right-0 z-40 flex w-[404px] max-w-full flex-col border-l border-edge bg-surface shadow-modal"
	aria-label="Detalhes do agendamento"
>
	<!-- Cabeçalho: status + encaixe + fechar -->
	<div class="flex items-center gap-2 border-b border-edge px-4 py-3.5">
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
		<button
			type="button"
			onclick={onClose}
			aria-label="Fechar"
			class="ml-auto grid size-7.5 place-items-center rounded-md text-muted hover:bg-surface-2"
		>
			<X size={17} />
		</button>
	</div>

	<div class="min-h-0 flex-1 space-y-3.5 overflow-auto px-4 py-4 text-[13px]">
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

		<!-- Falta justificada (só com status faltou) -->
		{#if faltou && podeMexer}
			<form method="POST" action="?/justificar" use:enhance bind:this={justifyForm}>
				<input type="hidden" name="id" value={appt.id} />
				<input type="hidden" name="expected_version" value={appt.version} />
				<input type="hidden" name="justificada" value={String(!appt.falta_justificada)} />
				<div class="flex items-center gap-2.5 rounded-lg border border-edge px-3 py-2.5">
					<div class="min-w-0 flex-1">
						<div class="font-semibold">Falta justificada</div>
						<div class="text-[11.5px] text-faint">Não conta para o paciente nem debita pacote.</div>
					</div>
					<SwitchToggle
						checked={appt.falta_justificada}
						label="Justificar falta"
						onchange={() => justifyForm?.requestSubmit()}
					/>
				</div>
			</form>
		{/if}

		<!-- Paciente(s) -->
		{#if grupo}
			<div class="rounded-lg border border-edge">
				<div class="flex items-center justify-between border-b border-edge px-3 py-2 text-[12px] text-faint">
					<span>Pacientes na turma</span>
					<span class="font-mono">{participantes.length}/{capacidade}</span>
				</div>
				<ul class="divide-y divide-edge">
					{#each participantes as p (p.id)}
						<li class="flex items-center gap-2 px-3 py-2">
							<span class="truncate">{p.nome}</span>
							{#if p.faltas}<span class="ml-auto text-[11px] text-faint">{p.faltas} falta(s)</span>{/if}
						</li>
					{/each}
				</ul>
			</div>
		{:else if soloPaciente}
			<div class="rounded-lg border border-edge px-3 py-2.5">
				<div class="font-semibold">{soloPaciente.nome}</div>
				<div class="mt-0.5 flex items-center gap-2 text-[12px] text-faint">
					{#if soloPaciente.tel}<span class="font-mono">{soloPaciente.tel}</span>{/if}
					{#if soloPaciente.faltas != null}<span>· {soloPaciente.faltas} falta(s)</span>{/if}
				</div>
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

			<!-- Mudar status (protótipo :1807) -->
			<div>
				<div class="mb-1.5 text-[12px] text-faint">Mudar status</div>
				<div class="grid grid-cols-3 gap-2">
					{#each acoes as ac (ac.kind)}
						{@const Icon = ICON[ac.icon as keyof typeof ICON]}
						<form method="POST" action="?/{ac.kind}" use:enhance>
							<input type="hidden" name="id" value={appt.id} />
							<input type="hidden" name="expected_version" value={appt.version} />
							<button
								type="submit"
								disabled={ac.disabled || ac.on}
								title={ac.title}
								class="flex w-full items-center justify-center gap-1.5 rounded-lg border px-2 py-2 text-[12.5px] font-semibold transition-colors disabled:cursor-not-allowed
								{ac.on
									? 'border-current text-ink'
									: ac.disabled
										? 'border-edge text-faint opacity-55'
										: 'border-edge hover:bg-surface-2'}"
								style={ac.on && STATUS_META[ac.status].tone
									? `color:var(--color-${STATUS_META[ac.status].tone}); background:color-mix(in srgb, var(--color-${STATUS_META[ac.status].tone}) 10%, transparent)`
									: ''}
							>
								<Icon size={14} />
								{ac.label}
							</button>
						</form>
					{/each}
				</div>
			</div>

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

	{#if podeMexer && !terminal}
		<!-- Rodapé: enviar confirmação (fiel — só toast, não há mensageria na v1). -->
		<div class="border-t border-edge px-4 py-3">
			<button
				type="button"
				onclick={() => onToast('Confirmação enviada por WhatsApp')}
				class="flex w-full items-center justify-center gap-2 rounded-lg border border-edge bg-surface px-3 py-2.5 text-[13px] font-semibold hover:bg-surface-2"
			>
				<Send size={15} /> Enviar confirmação
			</button>
		</div>
	{/if}
</aside>
