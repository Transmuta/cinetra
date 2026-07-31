<script lang="ts">
	// "Próximas sessões" (doc 56). Nasceu de um defeito medido ao vivo: o histórico ordenava `desc`
	// sem recorte de data, então as sessões AGENDADAS encabeçavam "Histórico de atendimentos" com
	// o selo "Previsto" — o cartão afirmava como passado o que ainda não tinha acontecido.
	//
	// Separar não é só higiene de rótulo: "quando ele volta?" é a pergunta que a recepção faz com
	// o telefone na mão, e a ficha não a respondia em lugar nenhum.
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import Package from '@lucide/svelte/icons/package';
	import { appointmentHref, zonedParts } from '$lib/agenda';
	import { quandoSemDia } from '$lib/data-hora';
	import type { HistorySession } from '$lib/server/patients';

	let {
		sessions,
		more = false,
		timezone = 'America/Sao_Paulo',
		patientId
	}: {
		sessions: HistorySession[];
		/** o servidor cortou em `@proximas_na_ficha` — o resto está na agenda do paciente */
		more?: boolean;
		timezone?: string;
		patientId: string;
	} = $props();

	const quando = (iso: string) => quandoSemDia(iso, timezone);

	// O bloco daquela sessão, com o dia ao lado (doc 85).
	const linkDaSessao = (s: HistorySession) =>
		appointmentHref(s.appointment_id, zonedParts(s.starts_at, timezone).date);
</script>

<section class="rounded-[14px] border border-edge bg-surface p-5">
	<div class="mb-4 flex items-center gap-2.5">
		<span class="grid size-[30px] shrink-0 place-items-center rounded-lg bg-accent-subtle text-accent-text">
			<CalendarClock size={15} />
		</span>
		<h2 class="flex-1 text-[14px] font-bold">Próximas sessões</h2>
		{#if sessions.length}
			<span class="font-mono text-[11px] text-faint">{sessions.length}</span>
		{/if}
	</div>

	<div class="overflow-hidden rounded-[10px] border border-edge">
		{#if sessions.length === 0}
			<!-- "Não tem nada marcado" é resposta, não ausência dela: é o que destrava a oferta de
			     horário. O botão "Agendar" do cabeçalho da ficha é o caminho. -->
			<div class="p-5 text-center text-[13px] text-faint">Nenhuma sessão marcada.</div>
		{:else}
			<ul class="divide-y divide-edge">
				{#each sessions as s, i (s.id)}
					<li>
						<!-- A linha vira LINK para o bloco (doc 85). "Quando ele volta?" é respondida
						     aqui; a ação que vem depois — remarcar, confirmar, ver a observação — mora no
						     drawer daquela sessão, e não havia caminho da ficha até ele. -->
						<a
							href={linkDaSessao(s)}
							class="flex w-full items-center gap-2.5 px-3 py-2.5 hover:bg-surface-2"
						>
							<span
								class="inline-block size-2.5 shrink-0 rounded-full"
								style="background:{s.cor ?? 'var(--color-edge)'}"
							></span>
							<div class="min-w-0 flex-1">
								<div class="flex items-center gap-2">
									<span class="shrink-0 font-mono text-[11.5px] text-muted">
										{quando(s.starts_at)}
									</span>
									{#if s.package_id}
										<span
											class="inline-flex items-center gap-1 text-[11px] text-faint"
											title="Sessão de pacote"
										>
											<Package size={12} /> pacote
										</span>
									{/if}
								</div>
								<div class="truncate text-[12px] text-muted">
									{s.tipo ?? 'Sessão'}{s.profissional ? ` · ${s.profissional}` : ''}
								</div>
							</div>
							{#if i === 0}
								<!-- a resposta à pergunta do cartão é esta linha; sem a marca ela some no meio
								     das outras quatro -->
								<!-- Par accent-text/accent-subtle, e não `primary` sobre a tinta dele mesmo: desde a
								     ADR-020 `primary` é o sage da marca, e sage sobre a própria tinta de 14% dá
								     2,26:1 (o axe pegou em `a11y-interno`). Este par é o que o design system tem
								     para chip tingido, e o `contraste.test.ts` o fixa em 4,71 nos dois temas. -->
								<span
									class="shrink-0 rounded-full bg-accent-subtle px-2 py-0.5 text-[11px] font-semibold text-accent-text"
								>
									próxima
								</span>
							{/if}
						</a>
					</li>
				{/each}
			</ul>
		{/if}
	</div>

	{#if more}
		<a
			href="/agenda?paciente={patientId}"
			class="mt-2.5 inline-block text-[11.5px] font-semibold text-primary hover:underline"
		>
			Ver na agenda
		</a>
	{/if}
</section>
