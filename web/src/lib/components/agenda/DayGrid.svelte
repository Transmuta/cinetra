<script lang="ts">
	// Grid do dia (protótipo `renderDayGrid` :1588 / `renderColumn` :1622).
	//
	// Duas divergências deliberadas do protótipo, ambas do doc 25:
	//  - A faixa vertical é DERIVADA do expediente (A12), não 08–18 cravado;
	//  - a hachura é o buraco REAL de cada coluna, não um "ALMOÇO" 12–13 decorativo e igual
	//    para todo mundo (GAP-05). Colunas ficam visualmente diferentes, e isso é o correto.
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import AgendaEmptyState from './AgendaEmptyState.svelte';
	import AppointmentBlock from './AppointmentBlock.svelte';
	import OccupancyBar from './OccupancyBar.svelte';
	import { initials } from '$lib/format';
	import { avatarColor } from '$lib/avatar';
	import { occupancyRate } from '$lib/agenda-views';
	import {
		m2t,
		timeToMinutes,
		zonedParts,
		toInterval,
		gridRange,
		closedIntervals,
		conflictIds,
		needsAction,
		ocupaGrade,
		type Appointment,
		type AgendaProfessional,
		type ColumnAvailability,
		type AgendaAppointmentType
	} from '$lib/agenda';
	import { layoutAppts, columnWidth } from '$lib/agenda-layout';
	import { dropMinutes, passouLimiar } from '$lib/agenda-drag';

	let {
		date,
		today,
		timezone,
		agora,
		appointments,
		professionals,
		appointmentTypes,
		availability = [],
		patientNames = {},
		hidden = [],
		only = null,
		onEmptyClick,
		onSelect,
		onReschedule = undefined,
		onShowAll
	}: {
		date: string;
		today: string;
		timezone: string;
		/** Instante do SERVIDOR: a linha do agora nunca sai de Date.now(). */
		agora: string;
		appointments: Appointment[];
		professionals: AgendaProfessional[];
		appointmentTypes: AgendaAppointmentType[];
		availability?: ColumnAvailability[];
		patientNames?: Record<string, string>;
		hidden?: string[];
		/**
		 * Uma coluna só (mobile, protótipo :1703). Não é "ocultar os outros": é outro modo de
		 * leitura — a barra de chips escolhe de quem é a agenda, e o gutter encolhe junto.
		 */
		only?: string | null;
		onEmptyClick: (pre: { professional_id: string; hora: string }) => void;
		onSelect: (id: string) => void;
		/**
		 * Remarcar por arraste (Entrega 4). Ausente = arraste desligado (sem permissão, ou
		 * mobile). A data NUNCA muda no arraste (protótipo): só hora e coluna. `hora` já vem
		 * arredondada; quem converte para instante é o `+page` (com o fuso).
		 */
		onReschedule?: (pre: { id: string; professional_id: string; hora: string }) => void;
		onShowAll: () => void;
	} = $props();

	// Pixels por minuto (protótipo `ppm` :1228; o controle de densidade é código morto lá e
	// fica fora desta entrega).
	//
	// AN-01 / D1 (doc 64 §3.3): era `1.05`, e a essa densidade a sessão de 30 min — o caso mais
	// comum — tinha 31px. O card redesenhado da Figura 2 tem quatro linhas e pede ~76px, ou seja,
	// a proposta só apareceria em sessão de 85 min para cima e a tela real nunca se pareceria com
	// a imagem. A `2.55` a de 30 min passa a ter exatamente 76px e cabe inteira.
	//
	// O preço, aceito na decisão: a grade de uma jornada 07:00–20:00 sai de ~830px para ~2000px,
	// e o dia passa a ocupar cerca de duas telas e meia.
	//
	// ATENÇÃO ao mexer: a constante governa SETE coisas, não só a altura do card — `topDe`, a
	// altura total da grade (`gridH`), as faixas de indisponibilidade, o fantasma do arraste, o
	// `dropMinutes` e a linha do agora. Todas precisam de conferência VISUAL, não só de teste.
	const PPM = 1.6;
	// +8px em relação aos 66 originais: o cabeçalho da coluna ganhou a barra de ocupação (AN-01
	// sub `i`), que é o que o Dia mostrava como contagem crua e as outras visões já desenhavam.
	const HEADER = 74;
	const PAD = 14;
	/** Granularidade do clique em vazio (protótipo :1660). A-D1: sugestão, não regra. */
	const SNAP = 15;

	// Gutter estreito no modo de coluna única: com uma coluna só, 54px de calha comem espaço
	// que a tela pequena não tem de sobra (protótipo :1720 usa 34px).
	const GUTTER = $derived(only ? 34 : 54);

	// O rótulo tem de CABER na calha, e é por isso que ele encolhe junto com ela. Martian Mono
	// avança 0.7em: "08:00" a 10.5px mede 36.8px e, com os 8px de `right-2`, pede 44.8 — cabe
	// nos 54 do modo largo, estoura os 34 do estreito. O que sobra some no `overflow-auto` do
	// grid, e a tela mostrava "8:00" (o protótipo desenhava só a hora ali, :1720).
	// Como `gridRange` fecha a faixa na hora, todo rótulo é "HH:00" e o ":00" não informa nada.
	const rotuloHora = (min: number) => (only ? m2t(min).slice(0, 2) : m2t(min));

	const visiveis = $derived(
		professionals.filter((p) => !hidden.includes(p.id)).filter((p) => !only || p.id === only)
	);

	const tipoPorId = $derived(new Map(appointmentTypes.map((t) => [t.id, t])));
	const periodosPorProf = $derived(new Map(availability.map((d) => [d.professional_id, d.periods])));

	const doDia = $derived(appointments.filter((a) => visiveis.some((p) => p.id === a.professional_id)));
	const conflitos = $derived(conflictIds(appointments));

	const range = $derived(
		gridRange(
			visiveis.map((p) => periodosPorProf.get(p.id) ?? []),
			doDia.map((a) => toInterval(a, timezone))
		)
	);

	const horas = $derived(
		Array.from({ length: Math.floor((range.end - range.start) / 60) + 1 }, (_, i) => range.start + i * 60)
	);

	// Folga abaixo da última hora. Os 10px originais só evitavam que a borda cortasse a linha
	// final; com o card alto do AN-01 (uma sessão de 30 min ocupa 76px), o agendamento que termina
	// na última hora encostava no fim do scroll e ficava espremido contra a borda — sem respiro
	// para ler as quatro linhas nem para o hover/arraste sobrar. Uma hora de folga (60 × PPM) dá
	// ao último card o mesmo espaço em volta que qualquer outro tem.
	//
	// É espaço VISUAL apenas: a faixa de horas continua sendo `range`, então nem `topDe`, nem a
	// hachura, nem a linha do agora mudam, e clicar aqui embaixo cai no clamp de `emptyClick`
	// (último slot da faixa), como já caía nos 10px.
	const TAIL = 60 * PPM;

	const gridH = $derived(PAD + (range.end - range.start) * PPM + TAIL);

	const colunas = $derived(
		visiveis.map((prof) => {
			const appts = appointments
				.filter((a) => a.professional_id === prof.id)
				.sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at));
			const intervalos = appts.map((a) => toInterval(a, timezone));
			const lay = layoutAppts(intervalos);
			const periodos = periodosPorProf.get(prof.id) ?? [];

			// Ocupação da coluna pela fórmula ÚNICA do projeto (A-D12, doc 33): minutos ocupados
			// ÷ minutos de expediente — nunca "N de 9 slots". Reusa `occupancyRate`, a mesma que
			// Semana e Mês usam, porque foi a divergência entre duas contas que A-D11 chamou de
			// "gráfico que mente".
			// `intervalos` é o `map` de `appts` na MESMA ordem, então o par sai do índice — a
			// primeira versão fazia `appts.find(...)` dentro do filter e reprocurava a lista
			// inteira por bloco, num `$derived` que o tempo real reexecuta a cada push.
			const ocupados = intervalos.reduce(
				(s, iv, i) => (ocupaGrade(appts[i]) ? s + (iv.end - iv.start) : s),
				0
			);
			const expediente = periodos.reduce(
				(s, [a, b]) => s + Math.abs(timeToMinutes(String(b)) - timeToMinutes(String(a))),
				0
			);

			return {
				prof,
				appts,
				intervalos: new Map(intervalos.map((i) => [i.id, i])),
				lay,
				width: columnWidth(lay.maxLanes),
				buracos: closedIntervals(periodos, range),
				ativos: appts.filter(ocupaGrade).length,
				ocupacao: occupancyRate(ocupados, expediente),
				temConflito: appts.some((a) => conflitos.has(a.id))
			};
		})
	);

	const agoraMin = $derived(zonedParts(agora, timezone).minutes);
	const mostraAgora = $derived(
		date === today && agoraMin >= range.start && agoraMin <= range.end
	);

	const topDe = (min: number) => PAD + (min - range.start) * PPM;

	// ---- Arraste (Entrega 4, protótipo `startDrag` :1231) -----------------------------------
	//
	// Clique e arraste começam com o MESMO `pointerdown` num bloco. O que os separa é o limiar
	// (`passouLimiar`): abaixo dele é clique (abre o drawer, via `onSelect` do bloco); acima é
	// arraste. No `pointerup`, se arrastou, calcula coluna (eixo X) + minuto (eixo Y) e remarca
	// — e suprime o clique que dispararia logo depois, senão soltar o bloco abriria o drawer.
	const ivPorId = $derived(
		new Map(
			colunas.flatMap((c) => c.appts.map((a) => [a.id, { iv: c.intervalos.get(a.id)!, profId: c.prof.id }]))
		)
	);

	type Drag = {
		id: string;
		dur: number;
		/** Offset de onde o ponteiro pegou o bloco (protótipo `grabDy` :1237). */
		grabDy: number;
		/** Coluna de origem: o fallback quando o ponteiro sai da faixa das colunas (:1243). */
		origProfId: string;
		downX: number;
		downY: number;
		pointerId: number;
		active: boolean;
		/** Destino (o fantasma): coluna, minuto do topo e rótulo. `null` até passar o limiar. */
		profId: string | null;
		startMin: number | null;
		hora: string | null;
	};
	let drag = $state<Drag | null>(null);
	let justDragged = false;
	let gridEl: HTMLElement | undefined = $state();

	// Coluna + topo do corpo sob um X da tela — por VARREDURA dos retângulos das colunas, não por
	// `elementFromPoint` (protótipo :1242). A diferença importa: varrer nunca "perde" a coluna
	// sobre o cabeçalho, a calha de horas ou um vão — cai na coluna cujo X envolve o ponteiro, e
	// fora de todas mantém a de origem. `elementFromPoint` devolvia `null` ali e o drop virava
	// no-op silencioso.
	function colunaEm(clientX: number, origProfId: string) {
		if (!gridEl) return { profId: origProfId, bodyTop: 0 };
		const cols = Array.from(gridEl.querySelectorAll<HTMLElement>('[data-prof-id]'));
		let profId = origProfId;
		for (const col of cols) {
			const r = col.getBoundingClientRect();
			if (clientX >= r.left && clientX <= r.right) {
				profId = col.dataset.profId ?? origProfId;
				break;
			}
		}
		const alvoCol = gridEl.querySelector<HTMLElement>(`[data-prof-id="${profId}"] [data-column-body]`);
		return { profId, bodyTop: alvoCol?.getBoundingClientRect().top ?? 0 };
	}

	function alvo(clientX: number, clientY: number, d: Drag) {
		const c = colunaEm(clientX, d.origProfId);
		const startMin = dropMinutes(clientY, c.bodyTop, range, PPM, PAD, d.dur, SNAP, d.grabDy);
		return { profId: c.profId, startMin, hora: m2t(startMin) };
	}

	function onPointerDown(event: PointerEvent) {
		if (!onReschedule) return;
		const el = (event.target as HTMLElement).closest('[data-appt-id]') as HTMLElement | null;
		const id = el?.dataset.apptId;
		if (!id) return;
		const info = ivPorId.get(id);
		// Cancelado não se arrasta (não disputa a grade — mesma regra de `ocupaGrade`).
		if (!info || !ocupaGrade({ status: appointments.find((a) => a.id === id)!.status })) return;

		drag = {
			id,
			dur: info.iv.end - info.iv.start,
			grabDy: event.clientY - el.getBoundingClientRect().top,
			origProfId: info.profId,
			downX: event.clientX,
			downY: event.clientY,
			pointerId: event.pointerId,
			active: false,
			profId: null,
			startMin: null,
			hora: null
		};
		// A captura do ponteiro NÃO acontece aqui: enquanto o gesto ainda pode virar clique, ela
		// desviaria o `mouseup` (e com ele o `click`, que sai no ancestral comum de down e up)
		// para o grid — o `onclick` do <button> do bloco nunca dispararia e o drawer não abriria.
		// Só capturamos quando o gesto vira arraste de fato, em `onPointerMove`.
	}

	function onPointerMove(event: PointerEvent) {
		if (!drag) return;
		const active = drag.active || passouLimiar(event.clientX - drag.downX, event.clientY - drag.downY);
		// Virou arraste agora: captura o ponteiro para não perder o gesto se ele sair do grid.
		if (active && !drag.active) {
			(event.currentTarget as HTMLElement).setPointerCapture(drag.pointerId);
		}
		const preview = active ? alvo(event.clientX, event.clientY, drag) : null;
		drag = {
			...drag,
			active,
			profId: preview?.profId ?? null,
			startMin: preview?.startMin ?? null,
			hora: preview?.hora ?? null
		};
	}

	function onPointerUp(event: PointerEvent) {
		const d = drag;
		drag = null;
		if (!d || !d.active || !onReschedule) return;

		// Soltar abre um `click` logo em seguida (é o mesmo gesto): suprimi-lo evita abrir o
		// drawer por cima da remarcação.
		justDragged = true;

		const t = alvo(event.clientX, event.clientY, d);
		onReschedule({ id: d.id, professional_id: t.profId, hora: t.hora });
	}

	// Captura ANTES do clique do bloco: se acabou de arrastar, engole o clique.
	function onClickCapture(event: MouseEvent) {
		if (!justDragged) return;
		justDragged = false;
		event.stopPropagation();
		event.preventDefault();
	}

	// Clicar em vazio abre o modal já preenchido com coluna, data e hora arredondada.
	function emptyClick(event: MouseEvent, profId: string) {
		const alvo = event.target as HTMLElement;
		// O bloco é um <button> dentro do corpo da coluna: sem esta guarda, clicar num
		// agendamento também abriria o "criar em vazio" por bubbling.
		if (alvo.closest('[data-appt]')) return;

		const body = event.currentTarget as HTMLElement;
		const rect = body.getBoundingClientRect();
		const bruto = range.start + (event.clientY - rect.top - PAD) / PPM;
		const minutos = Math.max(
			range.start,
			Math.min(range.end - SNAP, Math.round(bruto / SNAP) * SNAP)
		);
		onEmptyClick({ professional_id: profId, hora: m2t(minutos) });
	}
</script>

{#if !visiveis.length}
	<AgendaEmptyState {onShowAll} />
{:else}
	<div class="relative h-full overflow-auto bg-canvas">
		<!-- svelte-ignore a11y_no_static_element_interactions -->
		<div
			bind:this={gridEl}
			class="relative flex"
			style="min-width:{GUTTER + colunas.reduce((s, c) => s + c.width, 0)}px"
			onpointerdown={onPointerDown}
			onpointermove={onPointerMove}
			onpointerup={onPointerUp}
			onclickcapture={onClickCapture}
		>
			<!-- Gutter de horas, sticky à esquerda. -->
			<div class="sticky left-0 z-6 shrink-0 bg-canvas" style="width:{GUTTER}px">
				<div class="sticky top-0 z-7 border-b border-edge bg-canvas" style="height:{HEADER}px"></div>
				<div class="relative" data-testid="hour-gutter" style="height:{gridH}px">
					{#each horas as h (h)}
						<span
							class="absolute right-2 -translate-y-1/2 font-mono text-[10.5px] tabular-nums text-faint"
							style="top:{topDe(h)}px">{rotuloHora(h)}</span
						>
					{/each}
				</div>
			</div>

			{#each colunas as col (col.prof.id)}
				<div
					data-column
					data-prof-id={col.prof.id}
					class="relative border-l border-edge"
					style="flex:1 0 {col.width}px; min-width:{col.width}px"
				>
					<!-- A cor do profissional aparece em DOIS lugares e só neles (Figura 2, regra 4):
					     o sublinhado do cabeçalho e a faixa lateral do card. Antes ela era o
					     pontinho da linha 1 do bloco, disputando espaço com mais cinco sinais. -->
					<div
						class="sticky top-0 z-5 bg-surface px-2.5 py-2"
						style="height:{HEADER}px; border-bottom:2px solid {avatarColor(col.prof.cor_indice)}"
					>
						<div class="flex items-center gap-2">
							<span
								class="grid size-6.5 shrink-0 place-items-center rounded-full text-[10px] font-bold text-white"
								style="background:{avatarColor(col.prof.cor_indice)}"
							>
								{initials(col.prof.nome)}
							</span>
							<div class="min-w-0 flex-1">
								<div class="truncate text-[13px] font-semibold">{col.prof.nome}</div>
								<div class="truncate font-mono text-[10px] text-faint">
									{col.prof.crefito ?? ''}
								</div>
							</div>
							{#if col.temConflito}
								<!-- O protótipo mostrava `maxLanes ×` aqui (:1639), que é a sobreposição
								     máxima e acende até com encaixe. Um aviso booleano não mente. -->
								<span
									title="Conflito de horário nesta coluna"
									class="inline-flex items-center gap-0.75 rounded px-1 py-0.5 text-[9.5px] font-bold text-danger"
									style="background:color-mix(in srgb, var(--color-danger) 14%, transparent)"
								>
									<TriangleAlert size={11} />
								</span>
							{/if}
							<span class="font-mono text-[10px] font-semibold text-muted">{col.ativos}</span>
						</div>

						<!-- HOM-021 é sobre relatórios, mas a queixa é a mesma aqui: número sem
						     definição vira contestação. O `title` carrega a fórmula canônica. -->
						<div class="mt-1.5">
							<OccupancyBar
								rate={col.ocupacao}
								title="Ocupação: minutos ocupados ÷ minutos de expediente{col.ocupacao === null
									? ' — sem expediente neste dia'
									: ` — ${Math.round(col.ocupacao * 100)}%`}"
							/>
						</div>
					</div>

					<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
					<div
						data-column-body
						class="relative cursor-copy"
						style="height:{gridH}px"
						onclick={(e) => emptyClick(e, col.prof.id)}
					>
						{#each horas as h (h)}
							<div class="absolute inset-x-0 border-t border-edge" style="top:{topDe(h)}px"></div>
							{#if h + 30 <= range.end}
								<div
									class="absolute inset-x-0 border-t border-dashed border-edge/60"
									style="top:{topDe(h + 30)}px"
								></div>
							{/if}
						{/each}

						{#each col.buracos as [ini, fim] (ini)}
							<div
								data-closed
								class="pointer-events-none absolute inset-x-0 border-y border-edge"
								style="top:{topDe(ini)}px; height:{(fim - ini) * PPM}px;
								       background:repeating-linear-gradient(135deg, color-mix(in srgb, var(--color-muted) 8%, transparent) 0 7px, transparent 7px 14px)"
							></div>
						{/each}

						{#each col.appts as a (a.id)}
							{@const iv = col.intervalos.get(a.id)}
							{#if iv}
								<AppointmentBlock
									appt={a}
									tipo={tipoPorId.get(a.appointment_type_id)}
									slot={col.lay.byId[a.id] ?? { lane: 0, lanes: 1 }}
									top={topDe(iv.start)}
									height={(iv.end - iv.start) * PPM}
									conflict={conflitos.has(a.id)}
									action={needsAction(a, agora)}
									dragging={drag?.active && drag.id === a.id}
									patientNames={a.patient_ids.map((id) => patientNames[id]).filter(Boolean)}
									profColor={avatarColor(col.prof.cor_indice)}
									startLabel={m2t(iv.start)}
									{onSelect}
								/>
							{/if}
						{/each}

						{#if drag?.active && drag.profId === col.prof.id && drag.startMin !== null}
							<!-- Fantasma: bloco tracejado teal na coluna-alvo, com a ALTURA real e o
							     horário de destino (protótipo :1651). É a prévia espacial de onde o
							     bloco pousa — o par do bloco de origem esmaecido. -->
							<div
								data-testid="drag-ghost"
								class="pointer-events-none absolute inset-x-1 z-9 flex items-start rounded-lg border-2 border-dashed border-teal bg-teal/12 px-1.5 py-1"
								style="top:{topDe(drag.startMin)}px; height:{Math.max(drag.dur * PPM - 2, 18)}px"
							>
								<span class="font-mono text-[10.5px] font-semibold text-teal-text">{drag.hora}</span>
							</div>
						{/if}
					</div>
				</div>
			{/each}
		</div>

		{#if mostraAgora}
			<div
				data-testid="now-line"
				class="pointer-events-none absolute z-8 h-0"
				style="top:{HEADER + topDe(agoraMin)}px; left:{GUTTER}px; right:0"
			>
				<div class="absolute inset-x-0 top-0 border-t-2 border-teal"></div>
				<!-- O selo recua para dentro da calha (protótipo :1620 recua 44px fixos). Fixo ele
				     também estourava a calha estreita — começava em -10px e era cortado —, então o
				     recuo é limitado pela calha: 44 no modo largo, 34 no estreito. Aqui o ":00" não
				     pode sumir (é o minuto do agora), o selo é que se ajusta. -->
				<span
					class="absolute -top-2.25 rounded bg-teal px-1.25 font-mono text-[10px] font-semibold text-white"
					style="left:{-Math.min(GUTTER, 44)}px"
				>
					{m2t(agoraMin)}
				</span>
			</div>
		{/if}

	</div>
{/if}
