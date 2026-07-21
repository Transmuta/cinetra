<script lang="ts">
	import CalendarSearch from '@lucide/svelte/icons/calendar-search';
	import { initials } from '$lib/format';
	import { actionLabel, formatAt, dayKey, type AuditEntry } from '$lib/audit';
	import FieldDiff from './FieldDiff.svelte';

	// Uma entrada do feed de auditoria (doc 25 §11.4): quem · qual ação · qual registro · quando,
	// e o diff campo-a-campo por baixo. `entry.at` é QUANDO a mudança foi gravada; `entry.starts_at`
	// (só no appointment) é o horário do agendamento em si — os dois são coisas diferentes e por
	// isso aparecem em lugares diferentes.
	let { entry, timezone }: { entry: AuditEntry; timezone: string } = $props();

	const actorName = $derived(entry.actor?.nome ?? 'Sistema');

	// Contexto do registro: no agendamento, o profissional; no participante, o paciente.
	const contextName = $derived(
		entry.resource === 'attendance' ? (entry.patient?.nome ?? null) : (entry.professional?.nome ?? null)
	);

	// "Ver na agenda" leva ao DIA do agendamento (a agenda lê `?date=`). Só faz sentido quando há
	// `starts_at` — o participante não o carrega nesta fatia.
	const agendaHref = $derived(entry.starts_at ? `/agenda?date=${dayKey(entry.starts_at, timezone)}` : null);

	// O create já se explica pelo verbo ("Agendou") + o contexto; o diff cheio de "— → valor"
	// seria ruído. Só as ATUALIZAÇÕES mostram o antes/depois.
	const showDiff = $derived(entry.action_type !== 'create' && entry.diff.length > 0);
</script>

<article class="flex gap-3 px-3.5 py-3">
	<!-- Avatar do autor: neutro (o usuário não tem cor de agenda), só as iniciais. -->
	<span
		class="mt-0.5 grid size-7 shrink-0 place-items-center rounded-full border border-edge bg-surface-2 text-[10px] font-bold text-muted"
		aria-hidden="true"
	>
		{initials(actorName)}
	</span>

	<div class="min-w-0 flex-1">
		<div class="flex items-baseline justify-between gap-3">
			<div class="min-w-0 text-[13px] leading-snug">
				<span class="font-semibold text-ink">{actorName}</span>
				<span class="text-muted">{actionLabel(entry).toLowerCase()}</span>
				{#if contextName}
					<span class="text-faint">·</span>
					<span class="text-muted">{contextName}</span>
				{/if}
			</div>
			<time class="shrink-0 whitespace-nowrap font-mono text-[11px] text-faint" datetime={entry.at}>
				{formatAt(entry.at, timezone)}
			</time>
		</div>

		{#if showDiff}
			<FieldDiff resource={entry.resource} diff={entry.diff} {timezone} />
		{/if}

		{#if agendaHref}
			<a
				href={agendaHref}
				class="mt-1.5 inline-flex items-center gap-1 text-[11.5px] font-medium text-teal-text hover:underline"
			>
				<CalendarSearch size={12} /> Ver na agenda
			</a>
		{/if}
	</div>
</article>
