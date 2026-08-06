<script lang="ts">
	// "Novo pacote" (Fatia 3) — o construtor de grade com prévia AO VIVO (o save-gate, doc 02 §1.5).
	// O usuário monta a série (tipo, profissional, dias·horários, total, data-âncora); a cada ajuste
	// a tela pede a prévia ao servidor (`/pacotes/preview`) e desenha as ocorrências classificadas.
	// Só então cria: se o mundo recusa (fora do expediente, ou conflito), a prévia mostra o porquê e
	// oferece "agendar mesmo assim" — salvo o fora-do-expediente, que é bloqueio absoluto (D14, o
	// encaixe não isenta indisponibilidade).
	//
	// ## A reorganização do doc 69 §8
	//
	// A tela era um fluxo contínuo de oito controles em três grades diferentes empilhadas, onde o
	// campo mais consequente (falta punitiva, que é IMUTÁVEL depois) tinha o mesmo peso visual do
	// menos consequente (a cor). Agora são três seções numeradas — **o quê**, **quando**, **a regra
	// da falta** — e a prévia. Saíram dois campos:
	//
	//  - **Nome**: derivado do tipo + total ("Pilates 10"). O pacote *é* o tipo de atendimento, que
	//    já tem nome, sigla e duração cadastrados; pedir um nome era friccionar a decisão menos
	//    importante logo na primeira linha.
	//  - **Cor**: herda a do tipo. Duas paletas para o mesmo bloco na agenda produziam duas verdades.
	//
	// Os dois continuam viajando no payload (o backend os exige, `allow_nil? false`) — derivados.
	import { untrack } from 'svelte';
	import CalendarPlus from '@lucide/svelte/icons/calendar-plus';
	import Check from '@lucide/svelte/icons/check';
	import Minus from '@lucide/svelte/icons/minus';
	import Plus from '@lucide/svelte/icons/plus';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import Lock from '@lucide/svelte/icons/lock';
	import Loader from '@lucide/svelte/icons/loader-circle';
	import Modal from '$lib/components/Modal.svelte';
	import Field, { CONTROL_CLASS, CONTROL_PX } from '$lib/components/Field.svelte';
	import { DOW_LABELS, diaMes, diaSemana } from '$lib/data-hora';
	import {
		NEW_PACKAGE_DEFAULTS,
		PACKAGE_MAX_TOTAL,
		issueLabel,
		hasHardBlock,
		type PackagePreviewResponse,
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
	// default e passam a ser do usuário — o `untrack` torna explícita a captura do valor inicial.
	let typeId = $state(untrack(() => tipos[0]?.id ?? ''));
	let profId = $state(untrack(() => professionals[0]?.id ?? ''));
	let total = $state<number>(NEW_PACKAGE_DEFAULTS.total);
	let dataInicio = $state(untrack(() => today));
	let faltaPunitiva = $state<boolean>(NEW_PACKAGE_DEFAULTS.falta_punitiva);

	// A grade: dias marcados + o horário de cada dia. O horário nasce às 08:00 quando o dia entra.
	let dows = $state<number[]>([]);
	let horarios = $state<Record<number, string>>({});

	const tipoSel = $derived(tipos.find((t) => t.id === typeId));

	function toggleDow(d: number) {
		if (dows.includes(d)) {
			dows = dows.filter((x) => x !== d);
		} else {
			dows = [...dows, d].sort((a, b) => a - b);
			if (!horarios[d]) horarios = { ...horarios, [d]: '08:00' };
		}
	}

	// "Igualar horários": propaga o horário do PRIMEIRO dia para os demais. Grade de 3 dias com o
	// mesmo horário era três ajustes iguais na mão (protótipo :732).
	function igualarHorarios() {
		const primeiro = horarios[dows[0]] ?? '08:00';
		horarios = Object.fromEntries(dows.map((d) => [d, primeiro]));
	}

	function stepTotal(delta: number) {
		total = Math.min(PACKAGE_MAX_TOTAL, Math.max(1, total + delta));
	}

	// Nome e cor DERIVADOS (ver o cabeçalho): o backend exige os dois, a tela não os pergunta.
	const nomeDerivado = $derived(tipoSel ? `${tipoSel.nome} ${total}` : `Pacote ${total}`);
	const corDerivada = $derived(tipoSel?.cor ?? NEW_PACKAGE_DEFAULTS.cor);

	// Forma completa o bastante para pedir prévia / salvar.
	const completo = $derived(
		!!typeId &&
			!!profId &&
			total >= 1 &&
			total <= PACKAGE_MAX_TOTAL &&
			!!dataInicio &&
			dows.length > 0 &&
			dows.every((d) => !!horarios[d])
	);

	// **Por que** o botão está desabilitado. Um CTA que apaga sem dizer nada obriga o usuário a
	// caçar o campo que falta — e o campo pode estar acima da dobra do modal (doc 69 §6.6).
	const motivoBloqueio = $derived.by(() => {
		if (!typeId) return 'Escolha o tipo de atendimento.';
		if (!profId) return 'Escolha o profissional.';
		if (total < 1) return 'O pacote precisa de ao menos 1 sessão.';
		if (total > PACKAGE_MAX_TOTAL) return `O pacote vai até no máximo ${PACKAGE_MAX_TOTAL} sessões.`;
		if (!dataInicio) return 'Escolha a data de início.';
		if (!dows.length) return 'Marque ao menos um dia da semana.';
		if (!dows.every((d) => !!horarios[d])) return 'Cada dia marcado precisa de um horário.';
		return '';
	});

	function buildInput(forcar: boolean) {
		return {
			nome: nomeDerivado,
			total,
			falta_punitiva: faltaPunitiva,
			cor: corDerivada,
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
				.then((d: PackagePreviewResponse) => {
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

	// ---- o resumo da série: a leitura que decide ----
	const agendaveis = $derived(preview?.ocorrencias.filter((o) => !o.feriado) ?? []);
	const feriados = $derived(preview?.ocorrencias.filter((o) => o.feriado).length ?? 0);
	const problemas = $derived(preview?.ocorrencias.filter((o) => o.bloqueia) ?? []);

	const resumo = $derived.by(() => {
		if (!agendaveis.length) return '';
		const de = curto(agendaveis[0].data);
		const ate = curto(agendaveis[agendaveis.length - 1].data);
		const n = agendaveis.length;
		const base = `${n} ${n === 1 ? 'sessão' : 'sessões'} · ${de} → ${ate}`;
		return feriados
			? `${base} · ${feriados} feriado ${feriados === 1 ? 'pulado' : 'pulados'} (série estendida)`
			: base;
	});

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

	// "27/07" — o chip da prévia.
	const curto = diaMes;

	// O chip diz a data; o resto (dia da semana, hora, problema) vai no `title` — repetir o mesmo
	// "08:00" em vinte linhas era ruído, não informação.
	function chipTitle(o: PreviewOccurrence): string {
		return [diaSemana(o.data), curto(o.data), '·', o.hhmm, issueLabel(o.issue) ? `· ${issueLabel(o.issue)}` : '']
			.filter(Boolean)
			.join(' ');
	}

	function chipTom(o: PreviewOccurrence): string {
		if (o.issue === 'fora_expediente' || o.issue === 'conflito' || o.issue === 'cheia')
			return 'border-danger/45 bg-danger/8 text-danger';
		if (o.feriado) return 'border-edge bg-surface text-faint line-through';
		if (o.issue === 'join') return 'border-accent-border bg-accent-subtle text-accent-text';
		return 'border-edge bg-surface text-muted';
	}

	const salvarLabel = $derived(forcarSave ? 'Agendar mesmo assim' : 'Criar pacote');
</script>

{#snippet secao(numero: string, titulo: string, aviso?: string)}
	<div class="mb-1.5 mt-3 flex items-center gap-2 first:mt-0">
		<span
			class="grid size-[18px] shrink-0 place-items-center rounded-full bg-surface2 font-mono text-micro font-bold text-faint"
		>
			{numero}
		</span>
		<span class="text-meta font-bold uppercase tracking-[.06em] text-faint">{titulo}</span>
		{#if aviso}
			<span class="ml-auto inline-flex items-center gap-1 text-micro font-semibold text-warning">
				<Lock size={11} /> {aviso}
			</span>
		{/if}
	</div>
{/snippet}

<Modal title="Novo pacote" {onClose} maxWidth="max-w-[600px]">
	<!-- 1 · O QUE: tipo e profissional definem o pacote; total e início dimensionam a série -->
	{@render secao('1', 'O que')}
	<div class="grid gap-x-3 md:grid-cols-2">
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
	</div>

	<div class="grid gap-x-3 md:grid-cols-2">
		<!-- stepper: mexer de 1 em 1 é o gesto real (o teclado continua valendo) -->
		<div class="mb-3">
			<label for="pkg-total" class="mb-[5px] block text-rotulo font-semibold text-muted">
				Sessões
			</label>
			<div class="flex items-center gap-1.5">
				<button
					type="button"
					aria-label="Uma sessão a menos"
					onclick={() => stepTotal(-1)}
					disabled={total <= 1}
					class="grid size-[38px] shrink-0 place-items-center rounded-controle border border-edge bg-surface hover:bg-surface-2 disabled:opacity-40"
				>
					<Minus size={15} />
				</button>
				<input
					id="pkg-total"
					type="number"
					min="1"
					max={PACKAGE_MAX_TOTAL}
					value={total}
					oninput={(e) => (total = Number(e.currentTarget.value))}
					class="h-[38px] w-full text-center {CONTROL_CLASS} {CONTROL_PX} font-mono"
				/>
				<button
					type="button"
					aria-label="Mais uma sessão"
					onclick={() => stepTotal(1)}
					disabled={total >= PACKAGE_MAX_TOTAL}
					class="grid size-[38px] shrink-0 place-items-center rounded-controle border border-edge bg-surface hover:bg-surface-2 disabled:opacity-40"
				>
					<Plus size={15} />
				</button>
			</div>
		</div>

		<!-- min=hoje: sem ele dava para materializar a série inteira atrás de hoje (doc 69 §6.5) -->
		<Field label="Começa em" type="date" mono min={today} bind:value={dataInicio} />
	</div>

	<!-- 2 · QUANDO: a grade fixa da semana -->
	{@render secao('2', 'Quando')}
	<div class="mb-3" role="group" aria-label="Grade semanal">
		<div class="flex flex-wrap gap-1.5">
			{#each DOW_LABELS as label, d (d)}
				<button
					type="button"
					onclick={() => toggleDow(d)}
					aria-pressed={dows.includes(d)}
					class="rounded-controle border px-2.5 py-1.5 text-rotulo font-semibold transition-colors {dows.includes(
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
			<div class="mt-2.5 rounded-cartao border border-edge bg-surface2 p-2.5">
				<div class="mb-1.5 flex items-center justify-between">
					<span class="text-meta font-bold uppercase tracking-[.04em] text-faint">
						Horário de cada dia
					</span>
					{#if dows.length > 1}
						<button
							type="button"
							onclick={igualarHorarios}
							class="text-meta font-semibold text-accent-text hover:underline"
						>
							Igualar horários
						</button>
					{/if}
				</div>
				<div class="flex flex-col gap-1.5">
					{#each dows as d (d)}
						<div class="flex items-center gap-2.5">
							<span class="w-9 shrink-0 text-rotulo font-semibold text-muted">{DOW_LABELS[d]}</span>
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
			</div>
		{:else}
			<p class="mt-2 text-rotulo text-faint">Marque os dias em que a sessão se repete.</p>
		{/if}
	</div>

	<!-- 3 · A REGRA DA FALTA: combinada com o paciente na venda, e imutável depois -->
	{@render secao('3', 'Regra da falta', 'não muda depois')}
	<div class="mb-3 overflow-hidden rounded-cartao border border-edge">
		<label
			class="flex cursor-pointer items-start gap-2.5 border-b border-edge px-3 py-2.5 {faltaPunitiva
				? 'bg-surface2'
				: ''}"
		>
			<input
				type="radio"
				name="falta"
				checked={faltaPunitiva}
				onchange={() => (faltaPunitiva = true)}
				class="mt-0.5 size-4 accent-primary"
			/>
			<span>
				<span class="block text-corpo font-semibold">Falta desconta uma sessão</span>
				<span class="block text-meta text-muted">
					Falta não justificada consome 1 das {total} sessões.
				</span>
			</span>
		</label>
		<label
			class="flex cursor-pointer items-start gap-2.5 px-3 py-2.5 {!faltaPunitiva
				? 'bg-surface2'
				: ''}"
		>
			<input
				type="radio"
				name="falta"
				checked={!faltaPunitiva}
				onchange={() => (faltaPunitiva = false)}
				class="mt-0.5 size-4 accent-primary"
			/>
			<span>
				<span class="block text-corpo font-semibold">Falta não desconta</span>
				<span class="block text-meta text-muted">
					A sessão é reposta; o pacote só anda com o que foi atendido.
				</span>
			</span>
		</label>
	</div>

	<!-- Prévia ao vivo: resumo primeiro, chips depois, problemas em lista própria -->
	<div class="mt-1 rounded-cartao border border-edge bg-surface2 p-3">
		<div class="mb-2 flex items-center gap-2">
			<CalendarPlus size={15} class="text-faint" />
			<span class="text-meta font-bold uppercase tracking-[.06em] text-faint">Prévia da série</span>
			{#if previewing}
				<Loader size={14} class="animate-spin text-faint" />
			{/if}
		</div>

		{#if !completo}
			<p class="py-3 text-center text-rotulo text-faint">
				Complete o tipo, o profissional e a grade para ver a série.
			</p>
		{:else if previewErro}
			<p class="py-3 text-center text-rotulo text-danger">
				Não foi possível calcular a prévia. Revise os dados e tente de novo.
			</p>
		{:else if preview}
			<!-- a frase que decide -->
			<p class="mb-2 text-rotulo font-semibold">{resumo}</p>

			<ul class="flex flex-wrap gap-1" aria-label="Datas da série">
				{#each preview.ocorrencias as o, i (i)}
					<li
						title={chipTitle(o)}
						class="rounded-controle border px-1.5 py-0.5 font-mono text-micro {chipTom(o)}"
					>
						{curto(o.data)}
					</li>
				{/each}
			</ul>

			{#if problemas.length}
				<div class="mt-2.5 border-t border-edge pt-2.5">
					<div class="mb-1.5 flex items-center gap-1.5 text-rotulo font-bold text-danger">
						<TriangleAlert size={14} />
						{problemas.length}
						{problemas.length === 1 ? 'horário com conflito' : 'horários com conflito'}
					</div>
					<ul
						class="flex max-h-32 flex-col gap-1 overflow-y-auto"
						aria-label="Horários com conflito"
					>
						{#each problemas as o, i (i)}
							<li class="flex items-baseline gap-2 text-meta">
								<span class="shrink-0 font-mono font-semibold">
									{curto(o.data)}
									{diaSemana(o.data)}
									{o.hhmm}
								</span>
								<span class="text-muted">{issueLabel(o.issue)}</span>
							</li>
						{/each}
					</ul>
					<p class="mt-2 text-meta text-muted">
						{#if bloqueioDuro}
							Há sessões <strong>fora do expediente</strong> — ajuste os horários (encaixe não libera).
						{:else}
							Você pode <strong>agendar mesmo assim</strong>: elas entram como encaixe.
						{/if}
					</p>
				</div>
			{/if}
		{/if}
	</div>

	{#snippet footer()}
		<!-- o motivo e o erro vivem no rodapé, ao lado do botão: no fim do scroll ninguém os via -->
		<div class="mr-auto min-w-0 text-left">
			{#if saveErro}
				<p class="text-rotulo font-semibold text-danger">{saveErro}</p>
			{:else if motivoBloqueio}
				<p class="text-rotulo text-muted">{motivoBloqueio}</p>
			{/if}
		</div>
		<button
			type="button"
			onclick={onClose}
			class="rounded-controle border border-edge-strong bg-surface px-3.5 py-2 text-corpo font-semibold hover:bg-surface-2"
		>
			Cancelar
		</button>
		<button
			type="button"
			onclick={salvar}
			disabled={!podeSalvar}
			class="inline-flex items-center gap-1.5 rounded-controle px-3.5 py-2 text-corpo font-semibold disabled:cursor-not-allowed disabled:opacity-60 {forcarSave
				? 'bg-warning-solid text-on-solid'
				: 'bg-primary text-on-primary'}"
		>
			{#if saving}<Loader size={14} class="animate-spin" />{:else if !forcarSave}<Check size={14} />{/if}
			{salvarLabel}
		</button>
	{/snippet}
</Modal>
