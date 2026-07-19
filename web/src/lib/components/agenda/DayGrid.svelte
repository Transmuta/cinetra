<script lang="ts">
	// Grid do dia (protótipo `renderDayGrid` :1588 / `renderColumn` :1622).
	//
	// Duas divergências deliberadas do protótipo, ambas do doc 25:
	//  - A faixa vertical é DERIVADA do expediente (A12), não 08–18 cravado;
	//  - a hachura é o buraco REAL de cada coluna, não um "ALMOÇO" 12–13 decorativo e igual
	//    para todo mundo (GAP-05). Colunas ficam visualmente diferentes, e isso é o correto.
	import EyeOff from '@lucide/svelte/icons/eye-off';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import AppointmentBlock from './AppointmentBlock.svelte';
	import { initials } from '$lib/format';
	import { avatarColor } from '$lib/avatar';
	import {
		m2t,
		zonedParts,
		toInterval,
		gridRange,
		closedIntervals,
		conflictIds,
		needsAction,
		type Appointment,
		type AgendaProfessional,
		type ColumnAvailability,
		type AgendaAppointmentType
	} from '$lib/agenda';
	import { layoutAppts, columnWidth } from '$lib/agenda-layout';

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
		onEmptyClick,
		onSelect,
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
		onEmptyClick: (pre: { professional_id: string; hora: string }) => void;
		onSelect: (id: string) => void;
		onShowAll: () => void;
	} = $props();

	// Pixels por minuto (protótipo `ppm` :1228; o controle de densidade é código morto lá e
	// fica fora desta entrega).
	const PPM = 1.05;
	const HEADER = 66;
	const GUTTER = 54;
	const PAD = 14;
	/** Granularidade do clique em vazio (protótipo :1660). A-D1: sugestão, não regra. */
	const SNAP = 15;

	const visiveis = $derived(professionals.filter((p) => !hidden.includes(p.id)));

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

	const gridH = $derived(PAD + (range.end - range.start) * PPM + 10);

	const colunas = $derived(
		visiveis.map((prof) => {
			const appts = appointments
				.filter((a) => a.professional_id === prof.id)
				.sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at));
			const intervalos = appts.map((a) => toInterval(a, timezone));
			const lay = layoutAppts(intervalos);
			return {
				prof,
				appts,
				intervalos: new Map(intervalos.map((i) => [i.id, i])),
				lay,
				width: columnWidth(lay.maxLanes),
				buracos: closedIntervals(periodosPorProf.get(prof.id) ?? [], range),
				ativos: appts.filter((a) => a.status !== 'cancelado').length,
				temConflito: appts.some((a) => conflitos.has(a.id))
			};
		})
	);

	const agoraMin = $derived(zonedParts(agora, timezone).minutes);
	const mostraAgora = $derived(
		date === today && agoraMin >= range.start && agoraMin <= range.end
	);

	const topDe = (min: number) => PAD + (min - range.start) * PPM;

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
	<!-- Estado vazio do protótipo (:1602). Só aparece por AÇÃO do usuário (ocultar todo
	     mundo na sidebar), que é justamente por que é fácil de esquecer. -->
	<div
		class="flex h-full flex-col items-center justify-center gap-2.5 bg-canvas p-6 text-center text-faint"
	>
		<EyeOff size={26} />
		<div class="text-[13.5px] font-semibold text-muted">Nenhum profissional em exibição</div>
		<div class="text-[12.5px]">
			Ative ao menos um profissional na barra lateral para ver a agenda.
		</div>
		<button
			type="button"
			onclick={onShowAll}
			class="mt-1 rounded-lg bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary hover:opacity-90"
		>
			Mostrar todos
		</button>
	</div>
{:else}
	<div class="relative h-full overflow-auto bg-canvas">
		<div class="relative flex" style="min-width:{GUTTER + colunas.reduce((s, c) => s + c.width, 0)}px">
			<!-- Gutter de horas, sticky à esquerda. -->
			<div class="sticky left-0 z-6 shrink-0 bg-canvas" style="width:{GUTTER}px">
				<div class="sticky top-0 z-7 border-b border-edge bg-canvas" style="height:{HEADER}px"></div>
				<div class="relative" data-testid="hour-gutter" style="height:{gridH}px">
					{#each horas as h (h)}
						<span
							class="absolute right-2 -translate-y-1/2 font-mono text-[10.5px] tabular-nums text-faint"
							style="top:{topDe(h)}px">{m2t(h)}</span
						>
					{/each}
				</div>
			</div>

			{#each colunas as col (col.prof.id)}
				<div
					data-column
					class="relative border-l border-edge"
					style="flex:1 0 {col.width}px; min-width:{col.width}px"
				>
					<div
						class="sticky top-0 z-5 border-b border-edge bg-surface px-2.5 py-2"
						style="height:{HEADER}px"
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
									patientNames={a.patient_ids.map((id) => patientNames[id]).filter(Boolean)}
									profColor={avatarColor(col.prof.cor_indice)}
									startLabel={m2t(iv.start)}
									{onSelect}
								/>
							{/if}
						{/each}
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
				<span
					class="absolute -top-2.25 left-[-44px] rounded bg-teal px-1.25 font-mono text-[10px] font-semibold text-white"
				>
					{m2t(agoraMin)}
				</span>
			</div>
		{/if}
	</div>
{/if}
