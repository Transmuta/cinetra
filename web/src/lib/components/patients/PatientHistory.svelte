<script lang="ts">
	// "Histórico" da ficha do paciente (C13, Frente 7) — a segunda aba que a Fatia 3 destravou
	// (Anexos seguem ocultos: dependem do prontuário, v2).
	//
	// A linha é a PRESENÇA dele, não o bloco: numa turma o bloco pode estar concluído com a
	// presença dele faltando (`attendance.ex:8`), e a ficha que mostrasse o desfecho do bloco
	// contaria uma sessão que ele não fez. O selo, portanto, sai do status da presença.
	import History from '@lucide/svelte/icons/history';
	import Package from '@lucide/svelte/icons/package';
	import { attendanceSelo, zonedParts, m2t } from '$lib/agenda';
	import type { HistorySession } from '$lib/server/patients';

	let {
		sessions,
		more = false,
		timezone = 'America/Sao_Paulo'
	}: {
		sessions: HistorySession[];
		/** o servidor cortou a lista (teto de leitura) — a tela avisa em vez de mentir */
		more?: boolean;
		timezone?: string;
	} = $props();

	function quando(iso: string): string {
		const { date, minutes } = zonedParts(iso, timezone);
		const [ano, mes, dia] = date.split('-');
		return `${dia}/${mes}/${ano} · ${m2t(minutes)}`;
	}

	const selo = (s: HistorySession) => attendanceSelo(s.status, s.falta_justificada);
</script>

<section class="mt-4 rounded-[14px] border border-edge bg-surface p-4.5">
	<div class="mb-3.5 flex items-center gap-2">
		<History size={17} class="text-faint" />
		<h2 class="text-[13px] font-bold uppercase tracking-[.04em] text-faint">Histórico</h2>
	</div>

	{#if sessions.length === 0}
		<div class="py-8 text-center text-[13px] text-faint">Nenhuma sessão registrada ainda.</div>
	{:else}
		<ul class="divide-y divide-edge">
			{#each sessions as s (s.id)}
				{@const tag = selo(s)}
				<li class="flex items-center gap-2.5 py-2.5">
					<span
						class="inline-block size-2.5 shrink-0 rounded-full"
						style="background:{s.cor ?? 'var(--color-edge)'}"
					></span>
					<div class="min-w-0 flex-1">
						<div class="flex items-center gap-2">
							<span class="font-mono text-[12.5px]">{quando(s.starts_at)}</span>
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
					<span
						class="shrink-0 rounded-full px-2 py-0.5 text-[11px] font-semibold"
						style="background:{tag.tone
							? `color-mix(in srgb, var(--color-${tag.tone}) 14%, transparent)`
							: 'var(--color-surface-2)'}; color:{tag.tone
							? `var(--color-${tag.tone})`
							: 'var(--color-muted)'}"
					>
						{tag.label}
					</span>
				</li>
			{/each}
		</ul>

		{#if more}
			<p class="mt-2.5 text-[11.5px] text-faint">
				Mostrando as sessões mais recentes — há mais no histórico.
			</p>
		{/if}
	{/if}
</section>
