<script lang="ts">
	// "Adicionar à fila de espera" / "Editar item da fila" (protótipo `modalAddFila` :2197).
	// Clone estrutural do NewAppointmentModal: um `<form>` com `use:enhance` cujos campos
	// compostos (profissionais preferidos, regras de disponibilidade) viajam como JSON em inputs
	// hidden, montados a partir de `$state`. Suporta edição (prefill de um `Entry`, `?/atualizar`).
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import Plus from '@lucide/svelte/icons/plus';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import Check from '@lucide/svelte/icons/check';
	import CalendarDays from '@lucide/svelte/icons/calendar-days';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import Modal from '$lib/components/Modal.svelte';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import Field, { CONTROL_CLASS, CONTROL_PX } from '$lib/components/Field.svelte';
	import PatientPicker from '$lib/components/agenda/PatientPicker.svelte';
	import ConflictErrorBox from '$lib/components/agenda/ConflictErrorBox.svelte';
	import PeriodEditor from '$lib/components/scheduling/PeriodEditor.svelte';
	import { initials } from '$lib/format';
	import { avatarColor, avatarStyle } from '$lib/avatar';
	import { stripTitle } from '$lib/patients';
	import { TIME_WINDOW_LABEL, type Entry, type Priority, type Professional, type Rule, type TimeWindow } from '$lib/waitlist';
	import type { AgendaPatient, SearchResult } from '$lib/agenda';
	import type { Period } from '$lib/scheduling';
	import { envio as criarEnvio } from '$lib/forms.svelte';

	let {
		entry = null,
		professionals,
		search,
		onClose,
		form = undefined
	}: {
		/** Presente = modo edição (prefill + `?/atualizar`); ausente = adicionar (`?/enqueue`). */
		entry?: Entry | null;
		professionals: Professional[];
		/** Injetado: a rota passa o fetch para `/fila/pacientes`; o teste passa um duplo. */
		search: (q: string) => Promise<SearchResult>;
		onClose: () => void;
		/** Resultado da action `enqueue`/`atualizar` — traz `error` do 422 (forma da regra). */
		form?: { action?: string; error?: string; code?: string } | null;
	} = $props();

	// `untrack`: o modal é montado por abertura, então estes campos partem do `entry` UMA vez e
	// passam a ser do usuário (mesmo padrão do NewAppointmentModal). Regras são clonadas em fundo
	// para não mutar o prop ao editar.
	let selected = $state<AgendaPatient[]>(
		untrack(() => (entry ? [{ id: entry.patient.id, nome: entry.patient.nome, tel: entry.patient.tel }] : []))
	);
	let prio = $state<Priority>(untrack(() => entry?.prio ?? 'normal'));
	let janela = $state<TimeWindow>(untrack(() => entry?.janela ?? 'qualquer'));
	let profIds = $state<string[]>(untrack(() => (entry ? [...entry.professional_ids] : [])));
	let rules = $state<Rule[]>(untrack(() => (entry ? entry.rules.map(cloneRule) : [])));
	let obs = $state(untrack(() => entry?.obs ?? ''));

	const editando = $derived(!!entry);

	// `reset: false` porque o erro fica DENTRO do modal: limpar os campos junto com o 422 apagaria
	// o que a pessoa acabou de preencher (ver `$lib/forms.svelte.ts`).
	const envio = criarEnvio({ reset: false });

	const podeSalvar = $derived(editando || selected.length > 0);
	const erro = $derived(
		form?.action === 'enqueue' || form?.action === 'atualizar' ? form?.error : undefined
	);

	// A cor do avatar do paciente segue o 1º profissional preferido (protótipo `profColor(firstProf)`);
	// sem preferido, a 1ª cor da paleta — como o `||'p1'` do protótipo.
	const patientColor = $derived(
		avatarColor(professionals.find((p) => p.id === profIds[0])?.cor_indice ?? 1)
	);

	const WINDOWS: TimeWindow[] = ['manha', 'tarde', 'qualquer'];
	// Seg → Sáb, Domingo por último (protótipo :2223).
	const DOW_BUTTONS = [
		{ dow: 1, label: 'Seg' },
		{ dow: 2, label: 'Ter' },
		{ dow: 3, label: 'Qua' },
		{ dow: 4, label: 'Qui' },
		{ dow: 5, label: 'Sex' },
		{ dow: 6, label: 'Sáb' },
		{ dow: 0, label: 'Dom' }
	];

	function cloneRule(r: Rule): Rule {
		return {
			...(r.id ? { id: r.id } : {}),
			tipo: r.tipo,
			dows: [...(r.dows ?? [])],
			data: r.data ?? null,
			periodos: (r.periodos ?? []).map((p): [string, string] => [p[0], p[1]])
		};
	}

	function pick(p: AgendaPatient) {
		selected = [p];
	}

	function toggleProf(id: string) {
		profIds = profIds.includes(id) ? profIds.filter((x) => x !== id) : [...profIds, id];
	}

	// "Dias da semana" e "Data específica" (protótipo :2204/:2205): cada uma nasce com um período.
	function addSemana() {
		rules = [...rules, { tipo: 'semana', dows: [1], data: null, periodos: [['14:00', '16:00']] }];
	}
	function addData() {
		rules = [...rules, { tipo: 'data', dows: [], data: null, periodos: [['08:00', '12:00']] }];
	}
	function removeRule(i: number) {
		rules = rules.filter((_, x) => x !== i);
	}
	function toggleDow(i: number, dow: number) {
		rules = rules.map((r, x) =>
			x !== i ? r : { ...r, dows: r.dows.includes(dow) ? r.dows.filter((d) => d !== dow) : [...r.dows, dow] }
		);
	}
	function setData(i: number, value: string) {
		rules = rules.map((r, x) => (x !== i ? r : { ...r, data: value || null }));
	}
	function setPeriodos(i: number, next: Period[]) {
		rules = rules.map((r, x) => (x !== i ? r : { ...r, periodos: next }));
	}
</script>

<Modal title={editando ? 'Editar item da fila' : 'Adicionar à fila de espera'} {onClose} maxWidth="max-w-[560px]">
	<form
		id="fila-form"
		method="POST"
		action={editando ? '?/atualizar' : '?/enqueue'}
		use:enhance={envio.submit}
	>
		{#if entry}<input type="hidden" name="id" value={entry.id} />{/if}
		<input type="hidden" name="professional_ids" value={JSON.stringify(profIds)} />
		<input type="hidden" name="janela" value={janela} />
		<input type="hidden" name="rules" value={JSON.stringify(rules)} />

		<Field label="Paciente">
			{#if entry}
				<!-- Edição: o paciente é a CHAVE do item (upsert por paciente) — não muda aqui. -->
				<div class="flex items-center gap-2.5 rounded-md border border-edge bg-surface-2 px-3 py-2">
					<span
						class="grid size-7 shrink-0 place-items-center rounded-full text-[10px] font-bold"
						style={avatarStyle(patientColor)}
					>
						{initials(entry.patient.nome)}
					</span>
					<span class="min-w-0 truncate text-[13px] font-semibold">{entry.patient.nome}</span>
				</div>
			{:else}
				<input type="hidden" name="patient_id" value={selected[0]?.id ?? ''} />
				<PatientPicker
					{selected}
					{search}
					onPick={pick}
					onRemove={() => (selected = [])}
				/>
			{/if}
		</Field>

		<Field label="Prioridade">
			{#snippet control()}
				<select name="prio" bind:value={prio} class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}">
					<option value="urgente">Urgente</option>
					<option value="alta">Alta</option>
					<option value="normal">Normal</option>
					<option value="baixa">Baixa</option>
				</select>
			{/snippet}
		</Field>

		<Field label="Profissionais preferidos">
			{#if professionals.length}
				<div class="flex flex-wrap gap-2">
					{#each professionals as p (p.id)}
						{@const on = profIds.includes(p.id)}
						<button
							type="button"
							onclick={() => toggleProf(p.id)}
							class="flex items-center gap-1.5 rounded-full border py-1.5 pl-1.5 pr-2.5 text-[12.5px] font-semibold {on
								? 'border-transparent bg-accent-subtle text-accent-text'
								: 'border-edge bg-surface text-ink hover:bg-surface-2'}"
						>
							<span
								class="grid size-5 place-items-center rounded-full text-[9px] font-bold"
								style={avatarStyle(p.cor_indice)}
							>
								{initials(p.nome)}
							</span>
							{stripTitle(p.nome)}{#if on}<Check size={13} />{/if}
						</button>
					{/each}
				</div>
				<p class="mt-1.5 text-[11.5px] text-faint">
					Pode escolher mais de um, ou deixar em branco para qualquer profissional.
				</p>
			{:else}
				<p class="text-[12px] text-faint">Nenhum profissional cadastrado ainda.</p>
			{/if}
		</Field>

		<!-- Disponibilidade do paciente: quando ele consegue vir para um encaixe (protótipo :2233). -->
		<div class="mb-3 rounded-[10px] border border-edge bg-surface p-3.5">
			<div class="text-[13px] font-bold">Disponibilidade do paciente</div>
			<div class="mb-3 text-[11.5px] text-muted">Quando ele consegue vir para um encaixe.</div>

			<div class="mb-1.5 text-[12px] font-semibold text-muted">Período preferido</div>
			<div class="mb-4 flex gap-1.5">
				{#each WINDOWS as w (w)}
					<button
						type="button"
						onclick={() => (janela = w)}
						aria-pressed={janela === w}
						class="flex-1 rounded-md border py-2 text-[12.5px] font-semibold {janela === w
							? 'border-accent bg-accent-subtle text-accent-text'
							: 'border-edge bg-surface text-muted hover:bg-surface-2'}"
					>
						{TIME_WINDOW_LABEL[w]}
					</button>
				{/each}
			</div>

			<div class="mb-2 text-[12px] font-semibold text-muted">
				Horários específicos <span class="font-normal text-faint">(opcional)</span>
			</div>

			{#if rules.length}
				<div class="mb-2.5 flex flex-col gap-2">
					{#each rules as rule, i (i)}
						<div class="rounded-[9px] border border-edge bg-surface p-3">
							<div class="mb-2.5 flex items-center justify-between">
								<span class="flex items-center gap-1.5 text-[12px] font-bold {rule.tipo === 'data' ? 'text-accent-text' : 'text-ink'}">
									{#if rule.tipo === 'data'}<CalendarClock size={14} /> Data específica{:else}<CalendarDays size={14} /> Dias da semana{/if}
								</span>
								<button
									type="button"
									onclick={() => removeRule(i)}
									aria-label="Remover regra {i + 1}"
									class="grid size-6.5 place-items-center rounded-md border border-edge bg-surface text-danger hover:bg-surface-2"
								>
									<Trash2 size={13} />
								</button>
							</div>

							{#if rule.tipo === 'semana'}
								<div class="mb-1.5 text-[11px] text-faint">Selecione os dias</div>
								<div class="mb-2.5 flex flex-wrap gap-1.5">
									{#each DOW_BUTTONS as d (d.dow)}
										{@const on = rule.dows.includes(d.dow)}
										<button
											type="button"
											onclick={() => toggleDow(i, d.dow)}
											aria-pressed={on}
											class="h-7 w-[34px] rounded-md border text-[11px] font-semibold {on
												? 'border-accent bg-accent-subtle text-accent-text'
												: 'border-edge bg-surface text-muted hover:bg-surface-2'}"
										>
											{d.label}
										</button>
									{/each}
								</div>
							{:else}
								<div class="mb-2.5">
									<input
										type="date"
										value={rule.data ?? ''}
										aria-label="Data da regra {i + 1}"
										onchange={(e) => setData(i, e.currentTarget.value)}
										class="h-[38px] max-w-[190px] {CONTROL_CLASS} {CONTROL_PX}"
									/>
								</div>
							{/if}

							<div class="mb-1.5 text-[11px] text-faint">Horários — pode ter mais de um</div>
							<PeriodEditor periods={rule.periodos} onchange={(next) => setPeriodos(i, next)} />
						</div>
					{/each}
				</div>
			{:else}
				<div class="mb-2.5 rounded-lg bg-surface-2 p-3 text-center text-[11.5px] text-muted">
					Sem horários específicos — encaixa em qualquer horário do período acima. Adicione dias da
					semana ou uma data se ele tiver horários certos.
				</div>
			{/if}

			<div class="flex gap-2">
				<button
					type="button"
					onclick={addSemana}
					class="flex items-center gap-1.5 rounded-lg border border-dashed border-edge px-3 py-2 text-[12px] font-semibold text-accent-text hover:bg-surface-2"
				>
					<Plus size={13} /> Dias da semana
				</button>
				<button
					type="button"
					onclick={addData}
					class="flex items-center gap-1.5 rounded-lg border border-dashed border-edge px-3 py-2 text-[12px] font-semibold text-accent-text hover:bg-surface-2"
				>
					<Plus size={13} /> Data específica
				</button>
			</div>
		</div>

		<Field label="Observação">
			{#snippet control()}
				<input
					name="obs"
					bind:value={obs}
					maxlength="500"
					placeholder="Ex.: dor aguda, encaminhamento…"
					class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}"
				/>
			{/snippet}
		</Field>

		<ConflictErrorBox {erro} onEncaixe={() => {}} />
	</form>

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-md border border-edge-strong bg-surface px-3.5 py-2 text-[13px] font-semibold hover:bg-surface-2"
		>
			Cancelar
		</button>
		<SubmitButton
			emVoo={envio.emVoo}
			form="fila-form"
			disabled={!podeSalvar}
			class="inline-flex items-center gap-1.5 rounded-md bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary disabled:cursor-not-allowed disabled:opacity-60"
		>
			{editando ? 'Salvar' : 'Adicionar à fila'}
		</SubmitButton>
	{/snippet}
</Modal>
