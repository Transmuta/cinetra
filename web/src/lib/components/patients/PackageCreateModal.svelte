<script lang="ts">
	// "Novo pacote" (Fatia 3) — o construtor de grade com prévia AO VIVO (o save-gate, doc 02 §1.5).
	// O usuário monta a série (tipo, profissional, dias·horários, total, data-âncora); a cada ajuste
	// a tela pede a prévia ao servidor (`/pacotes/preview`) e desenha as ocorrências classificadas.
	// Só então cria: se o mundo recusa (fora do expediente, ou conflito), a prévia mostra o porquê e
	// oferece "agendar mesmo assim" — salvo o fora-do-expediente, que é bloqueio absoluto (D14, o
	// encaixe não isenta indisponibilidade).
	import { untrack } from 'svelte';
	import CalendarPlus from '@lucide/svelte/icons/calendar-plus';
	import Check from '@lucide/svelte/icons/check';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Loader from '@lucide/svelte/icons/loader-circle';
	import Modal from '$lib/components/Modal.svelte';
	import Field, { CONTROL_CLASS, CONTROL_PX } from '$lib/components/Field.svelte';
	import {
		DOW_LABELS,
		PACKAGE_COLORS,
		NEW_PACKAGE_DEFAULTS,
		issueLabel,
		hasHardBlock,
		type PreviewResult,
		type PreviewOccurrence
	} from '$lib/packages';
	import type { AppointmentType } from '$lib/appointment-types';

	// Só o id/nome são usados — o mesmo shape leve que a ficha já carrega.
	type Prof = { id: string; nome: string };

	let {
		patientId,
		professionals,
		appointmentTypes,
		onClose,
		onCreated,
		today = new Date().toISOString().slice(0, 10)
	}: {
		patientId: string;
		professionals: Prof[];
		/** ativos E arquivados; o seletor filtra os ativos. */
		appointmentTypes: AppointmentType[];
		onClose: () => void;
		/** criado com sucesso: o pai recarrega a ficha e fecha o modal. */
		onCreated: () => void;
		/** data de hoje (AAAA-MM-DD); injetável para teste. */
		today?: string;
	} = $props();

	const tipos = $derived(appointmentTypes.filter((t) => t.ativo));

	// O modal remonta a cada abertura (`{#if criandoPacote}`), então estes campos partem UMA vez do
	// default e passam a ser do usuário — o `untrack` torna explícito que a captura do valor inicial
	// é intencional (mesmo padrão do NewAppointmentModal).
	let nome = $state('');
	let typeId = $state(untrack(() => tipos[0]?.id ?? ''));
	let profId = $state(untrack(() => professionals[0]?.id ?? ''));
	let total = $state<number>(NEW_PACKAGE_DEFAULTS.total);
	let dataInicio = $state(untrack(() => today));
	let cor = $state<string>(NEW_PACKAGE_DEFAULTS.cor);
	let faltaPunitiva = $state<boolean>(NEW_PACKAGE_DEFAULTS.falta_punitiva);

	// A grade: dias marcados + o horário de cada dia. O horário nasce às 08:00 quando o dia entra.
	let dows = $state<number[]>([]);
	let horarios = $state<Record<number, string>>({});

	function toggleDow(d: number) {
		if (dows.includes(d)) {
			dows = dows.filter((x) => x !== d);
		} else {
			dows = [...dows, d].sort((a, b) => a - b);
			if (!horarios[d]) horarios = { ...horarios, [d]: '08:00' };
		}
	}

	// Nome auto-sugerido a partir do tipo + total, enquanto o usuário não digitou nada. Vira do
	// usuário no primeiro toque (o `touched` trava a sugestão).
	let nomeTouched = $state(false);
	const nomeSugerido = $derived.by(() => {
		const t = tipos.find((x) => x.id === typeId);
		return t ? `${t.nome} ${total}` : '';
	});
	const nomeEfetivo = $derived(nomeTouched ? nome : nomeSugerido);

	// Forma completa o bastante para pedir prévia / salvar: tudo preenchido e todo dia marcado tem
	// horário. Sem isto a prévia bateria no servidor com grade meia-boca (400).
	const completo = $derived(
		!!nomeEfetivo.trim() &&
			!!typeId &&
			!!profId &&
			total >= 1 &&
			!!dataInicio &&
			dows.length > 0 &&
			dows.every((d) => !!horarios[d])
	);

	function buildInput(forcar: boolean) {
		return {
			nome: nomeEfetivo.trim(),
			total,
			falta_punitiva: faltaPunitiva,
			cor,
			data_inicio: dataInicio,
			patient_id: patientId,
			appointment_type_id: typeId,
			grade: {
				dows,
				horarios: Object.fromEntries(dows.map((d) => [String(d), horarios[d]])),
				professional_id: profId
			},
			forcar
		};
	}

	// ---- prévia ao vivo ----
	let preview = $state<PreviewResult | null>(null);
	let previewing = $state(false);
	let previewErro = $state(false);

	// A última série já enviada à prévia. Variável comum (não `$state`): o efeito só a compara,
	// nunca reage a ela — assim o guard não vira uma dependência que se re-dispara.
	let ultimaSerie: string | null = null;

	// Debounce: o efeito relê os campos e reagenda a cada tecla; só a última chamada dispara. O
	// `alive` evita escrever num modal já fechado (timer órfão), mesmo padrão do OfferSlotModal.
	//
	// O guard por `payload` é o que impede o LOOP: a página tem tempo real na casca (o `+layout`
	// reconecta e re-renderiza de tempos em tempos, passando novas referências de props), o que
	// re-executa este efeito. Sem comparar a série, cada re-execução re-buscava a prévia para
	// sempre — e `previewing` piscando travava o botão de salvar. Só re-busca quando a série muda.
	$effect(() => {
		// leituras rastreadas (o corpo do build depende delas):
		const payload = completo ? JSON.stringify(buildInput(false)) : null;
		if (payload === ultimaSerie) return;
		ultimaSerie = payload;

		if (!payload) {
			preview = null;
			previewErro = false;
			previewing = false;
			return;
		}

		let alive = true;
		previewing = true;
		const timer = setTimeout(() => {
			fetch(`/pacientes/${encodeURIComponent(patientId)}/pacotes/preview`, {
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: payload
			})
				.then((r) => (r.ok ? r.json() : { preview: null }))
				.then((d: { preview: PreviewResult | null }) => {
					if (!alive) return;
					preview = d.preview;
					previewErro = d.preview === null;
					previewing = false;
				})
				.catch(() => {
					if (!alive) return;
					preview = null;
					previewErro = true;
					previewing = false;
				});
		}, 300);

		return () => {
			alive = false;
			clearTimeout(timer);
		};
	});

	// O bloqueio duro (fora do expediente) não tem "agendar mesmo assim" — precisa corrigir. O mole
	// (conflito/turma cheia) o encaixe resolve. Espelha `Api.Packages.gate/2`.
	const bloqueioDuro = $derived(!!preview && hasHardBlock(preview));
	const bloqueioMole = $derived(!!preview && !preview.pode_salvar && !bloqueioDuro);
	const forcarSave = $derived(bloqueioMole);

	// ---- salvar ----
	let saving = $state(false);
	let saveErro = $state<string | null>(null);

	const podeSalvar = $derived(completo && !previewing && !bloqueioDuro && !saving && !!preview);

	async function salvar() {
		if (!podeSalvar) return;
		saving = true;
		saveErro = null;
		try {
			const res = await fetch(`/pacientes/${encodeURIComponent(patientId)}/pacotes`, {
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: JSON.stringify(buildInput(forcarSave))
			});
			const body = (await res.json().catch(() => ({}))) as {
				ok?: boolean;
				blocked?: { reason: string; preview: PreviewResult };
				error?: string;
			};

			if (res.status === 201 && body.ok) {
				onCreated();
				return;
			}
			// A prévia envelheceu entre ver e confirmar: alguém ocupou um slot. Reapresenta a prévia
			// nova (o servidor é a autoridade) e deixa o usuário reavaliar.
			if (res.status === 422 && body.blocked) {
				preview = body.blocked.preview;
				saveErro =
					body.blocked.reason === 'fora_expediente'
						? 'Há sessões fora do expediente. Ajuste os horários.'
						: 'O calendário mudou — revise os conflitos abaixo e confirme.';
			} else {
				saveErro = body.error || 'Não foi possível criar o pacote.';
			}
		} catch {
			saveErro = 'Falha de conexão com o servidor.';
		} finally {
			saving = false;
		}
	}

	// Rótulo curto de cada ocorrência: "25/07 · Ter". UTC no parse para não recuar um dia a oeste.
	const OCC_FMT = new Intl.DateTimeFormat('pt-BR', {
		day: '2-digit',
		month: '2-digit',
		weekday: 'short',
		timeZone: 'UTC'
	});
	function occLabel(o: PreviewOccurrence): string {
		return OCC_FMT.format(new Date(`${o.data}T12:00:00Z`));
	}

	function occTone(o: PreviewOccurrence): string {
		if (o.issue === 'fora_expediente' || o.issue === 'conflito' || o.issue === 'cheia')
			return 'border-danger/40 bg-danger/5';
		if (o.issue === 'feriado') return 'border-warning/40 bg-warning/8';
		if (o.issue === 'join') return 'border-teal-border bg-teal-subtle';
		return 'border-edge bg-surface';
	}

	const salvarLabel = $derived(forcarSave ? 'Agendar mesmo assim' : 'Criar pacote');
</script>

<Modal title="Novo pacote" {onClose} maxWidth="max-w-[620px]">
	<div class="grid gap-x-3 md:grid-cols-2">
		<Field label="Nome do pacote">
			{#snippet control()}
				<input
					value={nomeEfetivo}
					oninput={(e) => {
						nomeTouched = true;
						nome = e.currentTarget.value;
					}}
					placeholder="Ex.: Pilates 10"
					class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}"
				/>
			{/snippet}
		</Field>

		<Field label="Tipo de atendimento">
			{#snippet control()}
				<select bind:value={typeId} class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}">
					{#each tipos as t (t.id)}
						<option value={t.id}>{t.nome} ({t.duracao_minutos}min){t.grupo ? ' · grupo' : ''}</option>
					{/each}
				</select>
			{/snippet}
		</Field>

		<Field label="Profissional">
			{#snippet control()}
				<select bind:value={profId} class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX}">
					{#each professionals as p (p.id)}
						<option value={p.id}>{p.nome}</option>
					{/each}
				</select>
			{/snippet}
		</Field>

		<div class="grid grid-cols-2 gap-x-3">
			<Field label="Total de sessões">
				{#snippet control()}
					<input
						type="number"
						min="1"
						max="60"
						value={total}
						oninput={(e) => (total = Number(e.currentTarget.value))}
						class="h-[38px] w-full {CONTROL_CLASS} {CONTROL_PX} font-mono"
					/>
				{/snippet}
			</Field>
			<Field label="Início" type="date" mono bind:value={dataInicio} />
		</div>
	</div>

	<!-- Grade semanal: dias marcados + o horário de cada dia (RN-18). -->
	<div class="mb-3" role="group" aria-label="Grade semanal">
		<span class="mb-[5px] block text-[12px] font-semibold text-muted">Dias e horários</span>
		<div class="flex flex-wrap gap-1.5">
			{#each DOW_LABELS as label, d (d)}
				<button
					type="button"
					onclick={() => toggleDow(d)}
					aria-pressed={dows.includes(d)}
					class="rounded-[8px] border px-2.5 py-1.5 text-[12.5px] font-semibold transition-colors {dows.includes(
						d
					)
						? 'border-primary bg-primary text-on-primary'
						: 'border-edge bg-surface text-muted hover:bg-surface-2'}"
				>
					{label}
				</button>
			{/each}
		</div>

		{#if dows.length}
			<div class="mt-2.5 flex flex-col gap-1.5">
				{#each dows as d (d)}
					<div class="flex items-center gap-2.5">
						<span class="w-9 shrink-0 text-[12.5px] font-semibold text-muted">{DOW_LABELS[d]}</span>
						<input
							type="time"
							step="900"
							value={horarios[d] ?? '08:00'}
							oninput={(e) => (horarios = { ...horarios, [d]: e.currentTarget.value })}
							aria-label={`Horário de ${DOW_LABELS[d]}`}
							class="h-[34px] {CONTROL_CLASS} {CONTROL_PX} font-mono"
						/>
					</div>
				{/each}
			</div>
		{/if}
	</div>

	<div class="grid gap-x-3 md:grid-cols-2">
		<!-- Cor do cartão -->
		<div class="mb-3" role="group" aria-label="Cor">
			<span class="mb-[5px] block text-[12px] font-semibold text-muted">Cor</span>
			<div class="flex flex-wrap gap-1.5">
				{#each PACKAGE_COLORS as c (c)}
					<button
						type="button"
						onclick={() => (cor = c)}
						aria-label={`Cor ${c}`}
						aria-pressed={cor === c}
						class="grid size-7 place-items-center rounded-full ring-2 ring-offset-2 ring-offset-surface transition-all {cor ===
						c
							? 'ring-ink'
							: 'ring-transparent'}"
						style="background:{c}"
					>
						{#if cor === c}<Check size={14} class="text-white" />{/if}
					</button>
				{/each}
			</div>
		</div>

		<!-- Falta punitiva: do pacote, obrigatória na criação. -->
		<div class="mb-3">
			<span class="mb-[5px] block text-[12px] font-semibold text-muted">Falta desconta sessão?</span>
			<label class="flex cursor-pointer items-center gap-2 rounded-md border border-edge bg-surface px-3 py-2">
				<input type="checkbox" bind:checked={faltaPunitiva} class="size-4 accent-primary" />
				<span class="text-[13px] text-ink">
					Falta não justificada consome uma sessão do pacote
				</span>
			</label>
		</div>
	</div>

	<!-- Prévia ao vivo -->
	<div class="mt-1 rounded-[11px] border border-edge bg-surface2 p-3">
		<div class="mb-2 flex items-center gap-2">
			<CalendarPlus size={15} class="text-faint" />
			<span class="text-[12px] font-bold uppercase tracking-[.04em] text-faint">Prévia da série</span>
			{#if previewing}
				<Loader size={14} class="animate-spin text-faint" />
			{/if}
		</div>

		{#if !completo}
			<p class="py-3 text-center text-[12.5px] text-faint">
				Preencha o tipo, o profissional e ao menos um dia com horário para ver a série.
			</p>
		{:else if previewErro}
			<p class="py-3 text-center text-[12.5px] text-danger">
				Não foi possível calcular a prévia. Revise os dados e tente de novo.
			</p>
		{:else if preview}
			{#if preview.bloqueios > 0}
				<div
					class="mb-2 flex items-start gap-2 rounded-[9px] border border-danger/30 bg-danger/10 px-3 py-2 text-[12.5px] text-ink"
				>
					<TriangleAlert size={15} class="mt-px shrink-0 text-danger" />
					<span>
						{preview.bloqueios} de {preview.ocorrencias.length} sessões esbarram no calendário.
						{#if bloqueioDuro}
							Há sessões <strong>fora do expediente</strong> — ajuste os horários (encaixe não libera).
						{:else}
							Você pode <strong>agendar mesmo assim</strong> (entram como encaixe).
						{/if}
					</span>
				</div>
			{/if}

			<ul class="flex max-h-52 flex-col gap-1 overflow-y-auto">
				{#each preview.ocorrencias as o, i (i)}
					<li
						class="flex items-center justify-between gap-2 rounded-[8px] border px-2.5 py-1.5 text-[12.5px] {occTone(
							o
						)}"
					>
						<span class="flex items-center gap-2">
							<span class="font-mono text-muted">{occLabel(o)}</span>
							<span class="font-mono font-semibold">{o.hhmm}</span>
						</span>
						{#if issueLabel(o.issue)}
							<span class="text-[11px] font-semibold text-muted">{issueLabel(o.issue)}</span>
						{:else}
							<Check size={13} class="text-success" />
						{/if}
					</li>
				{/each}
			</ul>
		{/if}
	</div>

	{#if saveErro}
		<p class="mt-2 text-[12.5px] font-semibold text-danger">{saveErro}</p>
	{/if}

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-md border border-edge-strong bg-surface px-3.5 py-2 text-[13px] font-semibold hover:bg-surface-2"
		>
			Cancelar
		</button>
		<button
			type="button"
			onclick={salvar}
			disabled={!podeSalvar}
			class="inline-flex items-center gap-1.5 rounded-md px-3.5 py-2 text-[13px] font-semibold text-on-primary disabled:cursor-not-allowed disabled:opacity-60 {forcarSave
				? 'bg-warning'
				: 'bg-primary'}"
		>
			{#if saving}<Loader size={14} class="animate-spin" />{/if}
			{salvarLabel}
		</button>
	{/snippet}
</Modal>
