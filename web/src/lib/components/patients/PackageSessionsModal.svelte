<script lang="ts">
	// "Sessões do pacote" — a trilha (`modalSessoes` do protótipo
	// [`:638`](../../../../interface/Movimento.dc.html#L638)).
	//
	// É o que torna o pacote auditável na ficha: qual sessão já foi, qual faltou, qual está
	// segurada por uma pausa e qual é a próxima. O contador `usadas/total` diz *quantas*; só a
	// trilha diz **quais**.
	//
	// Busca sob demanda (`/pacientes/:id/pacotes/:pkg/sessoes`): é uma leitura por pacote, e a
	// ficha já faz seis em paralelo no `load`.
	import Loader from '@lucide/svelte/icons/loader-circle';
	import Modal from '$lib/components/Modal.svelte';
	import { appointmentHref, zonedParts, m2t } from '$lib/agenda';
	// O tipo da resposta vem do MESMO módulo que o `+server.ts` usa para respondê-la. Estava
	// redeclarado aqui, campo por campo (doc 94 §4.5) — e um valor novo em `estado` compilaria dos
	// dois lados enquanto o `switch` caía no default calado.
	import type { Package as Pkg, PackageSession, PackageSessionsResponse } from '$lib/packages';

	let {
		pkg,
		patientId,
		titulo,
		timezone = 'America/Sao_Paulo',
		onClose
	}: {
		pkg: Pkg;
		patientId: string;
		/** o nome do TIPO (a identidade do pacote), resolvido pela ficha */
		titulo: string;
		timezone?: string;
		onClose: () => void;
	} = $props();

	let sessoes = $state<PackageSession[] | null>(null);
	let erro = $state(false);

	$effect(() => {
		let alive = true;
		fetch(
			`/pacientes/${encodeURIComponent(patientId)}/pacotes/${encodeURIComponent(pkg.id)}/sessoes`
		)
			.then((r) => (r.ok ? r.json() : Promise.reject(new Error('falhou'))))
			.then((d: PackageSessionsResponse) => {
				if (alive) sessoes = d.sessions;
			})
			.catch(() => {
				if (alive) erro = true;
			});

		return () => {
			alive = false;
		};
	});

	// Rótulo e pintura de cada estado — o mesmo desenho do cartão (`pkgDot` do protótipo): cheia =
	// consumida, halo = próxima, contorno = por vir, tracejada = segurada, × = falta. O halo é
	// `box-shadow` inline pelo mesmo motivo do cartão: `ring-*` do Tailwind não aceita cor inline e
	// o offset aumentava a bolinha, quebrando o alinhamento da fila.
	//
	// Cancelada não chega aqui: a trilha é a série, não o cemitério dela (o servidor a filtra).
	const ESTADO: Record<string, { label: string; classe: string; estilo: string }> = {
		concluida: { label: 'Concluída', classe: 'border-transparent bg-primary', estilo: '' },
		proxima: {
			label: 'Próxima',
			classe: 'border-transparent bg-primary',
			estilo: 'box-shadow:0 0 0 3px color-mix(in srgb, var(--color-primary) 25%, transparent)'
		},
		agendada: { label: 'Agendada', classe: 'border-edge-strong', estilo: '' },
		segurada: { label: 'Segurada', classe: 'border-dashed border-faint opacity-60', estilo: '' },
		falta: { label: 'Falta', classe: 'border-transparent bg-danger-solid', estilo: '' }
	};

	const DOW = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
	function quando(iso: string): string {
		const { date, minutes } = zonedParts(iso, timezone);
		const [, mes, dia] = date.split('-');
		const dow = DOW[new Date(`${date}T12:00:00Z`).getUTCDay()];
		return `${dow} ${dia}/${mes} · ${m2t(minutes)}`;
	}
</script>

<Modal title="Sessões do pacote" {onClose} maxWidth="max-w-[480px]">
	<div class="mb-3 flex items-center gap-2.5 rounded-[11px] border border-edge bg-surface2 px-3 py-2.5">
		<span class="inline-block size-2.5 shrink-0 rounded-[3px]" style="background:{pkg.cor}"></span>
		<div class="min-w-0 flex-1">
			<div class="truncate text-[13.5px] font-bold">{titulo}</div>
		</div>
		<span class="shrink-0 font-mono text-[13px] font-bold">
			{pkg.usadas ?? 0}/{pkg.total}
		</span>
	</div>

	{#if erro}
		<p class="py-6 text-center text-[12.5px] text-danger">
			Não foi possível carregar as sessões deste pacote.
		</p>
	{:else if sessoes === null}
		<p class="flex items-center justify-center gap-2 py-6 text-[12.5px] text-faint">
			<Loader size={15} class="animate-spin" /> Carregando…
		</p>
	{:else if sessoes.length === 0}
		<p class="py-6 text-center text-[12.5px] text-faint">
			Nenhuma sessão materializada ainda — o agendamento roda em segundo plano.
		</p>
	{:else}
		<!-- a trilha: uma bolinha por sessão, na ordem -->
		<div class="mb-3 flex flex-wrap gap-x-2 gap-y-1.5" aria-hidden="true">
			{#each sessoes as s (s.attendance_id)}
				<span
					class="box-border size-3.5 shrink-0 rounded-full border-2 {ESTADO[s.estado].classe}"
					style={ESTADO[s.estado].estilo}
				></span>
			{/each}
		</div>

		<ul class="flex max-h-72 flex-col divide-y divide-edge overflow-y-auto">
			{#each sessoes as s, i (s.attendance_id)}
				<li>
					<!-- Cada sessão abre o seu bloco na agenda (doc 85). É a lista onde a pergunta "por
					     que esta ficou segurada / faltou?" nasce, e a resposta está no drawer. -->
					<a
						href={appointmentHref(s.appointment_id, zonedParts(s.starts_at, timezone).date)}
						class="flex items-center gap-2.5 rounded-md py-2 hover:bg-surface-2"
					>
						<span class="w-5 shrink-0 text-right font-mono text-[10px] text-faint">{i + 1}</span>
						<span
							class="box-border size-3.5 shrink-0 rounded-full border-2 {ESTADO[s.estado].classe}"
							style={ESTADO[s.estado].estilo}
						></span>
						<span class="min-w-0 flex-1 text-[12.5px] font-medium">{quando(s.starts_at)}</span>
						<span class="shrink-0 text-[11.5px] font-semibold text-muted">
							{ESTADO[s.estado].label}
						</span>
					</a>
				</li>
			{/each}
		</ul>
	{/if}

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-lg border border-edge px-3.5 py-2 text-[13px] font-semibold hover:bg-surface-2"
		>
			Fechar
		</button>
	{/snippet}
</Modal>
