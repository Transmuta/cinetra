<script lang="ts">
	// Visão Lista (protótipo `renderList` :1779): o mesmo dia da visão Dia, em linhas.
	//
	// Duas notas de fidelidade, uma mantida e outra deliberadamente quebrada:
	//
	//  - **Cancelado aparece** (mantido). É a única visão que os mostra, e é onde eles
	//    informam: riscado, dizendo que aquele horário foi desmarcado e não simplesmente
	//    nunca existiu.
	//  - **O toggle da sidebar VALE aqui** (quebrado de propósito, B-D1). No protótipo a
	//    Lista ignorava `hiddenProfs` — ocultar um profissional sumia com ele no grid e o
	//    deixava na lista, dois filtros discordando sobre a mesma tela.
	import CalendarOff from '@lucide/svelte/icons/calendar-off';
	import { STATUS_META, zonedParts, m2t, type Appointment } from '$lib/agenda';
	import type { AgendaProfessional, AgendaAppointmentType } from '$lib/agenda';
	import { avatarColor } from '$lib/avatar';
	import AgendaEmptyState from './AgendaEmptyState.svelte';

	let {
		appointments,
		professionals,
		appointmentTypes,
		patientNames = {},
		timezone,
		hidden = [],
		onSelect,
		onShowAll
	}: {
		appointments: Appointment[];
		professionals: AgendaProfessional[];
		appointmentTypes: AgendaAppointmentType[];
		patientNames?: Record<string, string>;
		timezone: string;
		hidden?: string[];
		onSelect: (id: string) => void;
		onShowAll: () => void;
	} = $props();

	// Com todas as colunas ocultas, a lista filtra tudo e o estado vazio diria "Nenhum
	// agendamento neste dia" — havendo agendamentos, apenas escondidos pelo filtro.
	const semColunas = $derived(professionals.filter((p) => !hidden.includes(p.id)).length === 0);

	const profById = $derived(new Map(professionals.map((p) => [p.id, p])));
	const typeById = $derived(new Map(appointmentTypes.map((t) => [t.id, t])));

	const rows = $derived.by(() => {
		const oculto = new Set(hidden);

		return appointments
			.filter((a) => !oculto.has(a.professional_id))
			.map((appt) => {
				const prof = profById.get(appt.professional_id);
				const tipo = typeById.get(appt.appointment_type_id);
				const nomes = appt.patient_ids.map((id) => patientNames[id] ?? 'Paciente');

				return {
					appt,
					meta: STATUS_META[appt.status],
					minutos: zonedParts(appt.starts_at, timezone).minutes,
					hora: m2t(zonedParts(appt.starts_at, timezone).minutes),
					cor: avatarColor(prof?.cor_indice ?? 1),
					// Turma mostra o tipo e quantos são; individual mostra a pessoa.
					titulo:
						tipo?.grupo && appt.patient_ids.length > 1
							? `${tipo.nome} · ${appt.patient_ids.length} pacientes`
							: (nomes[0] ?? 'Paciente'),
					subtitulo: [tipo?.nome, prof?.nome_exibicao || prof?.nome].filter(Boolean).join(' · ')
				};
			})
			.sort((a, b) => a.minutos - b.minutos || a.titulo.localeCompare(b.titulo, 'pt-BR'));
	});
</script>

{#if semColunas}
	<AgendaEmptyState {onShowAll} />
{:else if rows.length === 0}
	<!-- O protótipo não tinha estado vazio aqui: um dia sem nada renderizava um container
	     vazio, que parece tela quebrada. O grid do Dia ao menos se desenha sozinho. -->
	<div class="flex flex-col items-center justify-center gap-2 p-12 text-center">
		<span class="text-faint"><CalendarOff size={28} /></span>
		<p class="text-[13.5px] font-semibold">Nenhum agendamento neste dia</p>
		<p class="text-[12.5px] text-muted">
			Use a visão Dia para marcar um horário clicando num espaço livre.
		</p>
	</div>
{:else}
	<ul class="divide-y divide-edge">
		{#each rows as row (row.appt.id)}
			<li>
				<button
					type="button"
					onclick={() => onSelect(row.appt.id)}
					class="flex w-full items-center gap-3 px-4 py-2.75 text-left hover:bg-surface-2"
				>
					<span class="w-[46px] shrink-0 font-mono text-[11.5px] font-semibold tabular-nums">
						{row.hora}
					</span>

					<span
						class="size-[26px] shrink-0 rounded-full"
						style="background:{row.cor}"
						aria-hidden="true"
					></span>

					<span class="min-w-0 flex-1">
						<span
							class="block truncate text-[13.5px] font-semibold {row.meta.strike
								? 'text-faint line-through'
								: 'text-ink'}"
						>
							{row.titulo}
						</span>
						<span class="block truncate text-[12px] text-muted">{row.subtitulo}</span>
					</span>

					{#if row.appt.encaixe}
						<!-- AN-08: texto escuro fixo sobre o âmbar (2,0:1 com branco; 8,6:1 assim). -->
						<span class="shrink-0 rounded bg-warning-solid px-1.5 py-px text-[10px] font-bold text-on-solid">
							Encaixe
						</span>
					{/if}

					<!-- Todo status tem tom próprio (ver `StatusMeta.tone`), então o chip não precisa mais
					     do ramo "sem cor". O texto usa a variante `-text` quando ela existe (é o caso
					     do teal, cujo sólido não tem contraste sobre 14% dele mesmo) e cai no próprio
					     token quando não existe — a mesma expressão do badge do cartão. -->
					<span
						class="shrink-0 rounded-full px-1.5 py-px text-[10.5px] font-semibold"
						style="background:color-mix(in srgb, var(--color-{row.meta.tone}) 14%, transparent);
						       color:var(--color-{row.meta.tone}-text, var(--color-{row.meta.tone}))"
					>
						{row.meta.label}
					</span>
				</button>
			</li>
		{/each}
	</ul>
{/if}
