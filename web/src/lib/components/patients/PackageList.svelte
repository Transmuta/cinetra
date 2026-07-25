<script lang="ts">
	// A seção "Pacotes" da ficha do paciente (Fatia 3). Lista os pacotes com o contador derivado
	// (usadas/total), o chip de status e as ações de ciclo de vida (pausar/retomar/cancelar). A
	// criação é o botão que abre o modal (delegado ao pai). Fiel ao cartão de pacote do protótipo.
	import { enhance } from '$app/forms';
	import Package from '@lucide/svelte/icons/package';
	import Pause from '@lucide/svelte/icons/pause';
	import Play from '@lucide/svelte/icons/play';
	import Plus from '@lucide/svelte/icons/plus';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import { statusLabel, type Package as Pkg } from '$lib/packages';

	let {
		packages,
		canManage = false,
		onNew = undefined,
		onBulk = undefined
	}: {
		packages: Pkg[];
		/** owner·admin·recepcao·profissional podem mexer; a policy da API é a autoridade */
		canManage?: boolean;
		/** abre o modal de criação (o pai é dono dele) */
		onNew?: () => void;
		/** abre a massa (ajustar sessões futuras) daquele pacote — o pai é dono do modal */
		onBulk?: (pkg: Pkg) => void;
	} = $props();

	// O pacote em confirmação de cancelamento (destrutivo → ConfirmDialog). O form escondido é
	// submetido pelo `requestSubmit()` do dialog — mesmo padrão do "remover acesso" (equipe).
	let cancelling = $state<Pkg | null>(null);
	let cancelForm = $state<HTMLFormElement | null>(null);

	// Tom do chip por status: ativo=teal, pausado=warning, cancelado/concluído=faint.
	function chip(status: Pkg['status']): string {
		if (status === 'ativo') return 'bg-teal-subtle text-teal-text border-teal-border';
		if (status === 'pausado') return 'bg-warning/12 text-[#9a6a05] border-warning/45';
		return 'bg-surface2 text-faint border-edge';
	}

	// Barra de progresso das sessões usadas. `usadas` pode vir null (não carregado) → trata como 0.
	function pct(pkg: Pkg): number {
		const usadas = pkg.usadas ?? 0;
		return pkg.total > 0 ? Math.min(100, Math.round((usadas / pkg.total) * 100)) : 0;
	}
</script>

<section class="mt-4 rounded-[14px] border border-edge bg-surface p-4.5">
	<div class="mb-3.5 flex items-center justify-between gap-2">
		<div class="flex items-center gap-2">
			<Package size={17} class="text-faint" />
			<h2 class="text-[13px] font-bold uppercase tracking-[.04em] text-faint">Pacotes</h2>
		</div>
		{#if canManage}
			<button
				type="button"
				onclick={() => onNew?.()}
				class="inline-flex items-center gap-1.5 rounded-[8px] bg-primary px-2.75 py-1.5 text-[12.5px] font-semibold text-on-primary"
			>
				<Plus size={15} /> Novo pacote
			</button>
		{/if}
	</div>

	{#if packages.length === 0}
		<div class="py-8 text-center text-[13px] text-faint">Nenhum pacote ainda.</div>
	{:else}
		<div class="flex flex-col gap-2.5">
			{#each packages as pkg (pkg.id)}
				<div class="rounded-[11px] border border-edge bg-surface2 p-3.25">
					<div class="mb-2 flex items-start justify-between gap-2">
						<div class="min-w-0">
							<div class="flex items-center gap-2">
								<span
									class="inline-block size-2.5 shrink-0 rounded-full"
									style="background:{pkg.cor}"
								></span>
								<span class="truncate text-[13.5px] font-semibold">{pkg.nome}</span>
							</div>
							<div class="mt-0.5 font-mono text-[11px] text-muted">
								{pkg.restantes ?? pkg.total} de {pkg.total} restantes
							</div>
						</div>
						<span
							class="shrink-0 rounded-[6px] border px-2 py-0.5 text-[10.5px] font-semibold {chip(
								pkg.status
							)}"
						>
							{statusLabel(pkg.status)}
						</span>
					</div>

					<div class="h-1.5 overflow-hidden rounded-full bg-edge">
						<div class="h-full rounded-full bg-primary" style="width:{pct(pkg)}%"></div>
					</div>

					{#if canManage && (pkg.status === 'ativo' || pkg.status === 'pausado')}
						<div class="mt-2.5 flex items-center gap-2">
							{#if pkg.status === 'ativo'}
								<form method="POST" action="?/pausePackage" use:enhance>
									<input type="hidden" name="package_id" value={pkg.id} />
									<button
										type="submit"
										class="inline-flex items-center gap-1.5 rounded-[7px] border border-edge px-2.5 py-1 text-[12px] font-semibold text-muted hover:text-ink"
									>
										<Pause size={13} /> Pausar
									</button>
								</form>
							{:else}
								<form method="POST" action="?/resumePackage" use:enhance>
									<input type="hidden" name="package_id" value={pkg.id} />
									<button
										type="submit"
										class="inline-flex items-center gap-1.5 rounded-[7px] border border-edge px-2.5 py-1 text-[12px] font-semibold text-muted hover:text-ink"
									>
										<Play size={13} /> Retomar
									</button>
								</form>
							{/if}
							<!-- Massa (doc 41 etapa 3): mexe nas sessões FUTURAS do pacote. Só com o pacote
							     ativo — pausado tem as sessões seguradas, fora da agenda. -->
							{#if pkg.status === 'ativo' && onBulk}
								<button
									type="button"
									onclick={() => onBulk(pkg)}
									class="inline-flex items-center gap-1.5 rounded-[7px] border border-edge px-2.5 py-1 text-[12px] font-semibold text-muted hover:text-ink"
								>
									<CalendarClock size={13} /> Ajustar sessões
								</button>
							{/if}
							<button
								type="button"
								onclick={() => (cancelling = pkg)}
								class="text-[12px] font-semibold text-danger hover:underline"
							>
								Cancelar
							</button>
						</div>
					{/if}
				</div>
			{/each}
		</div>
	{/if}
</section>

<!-- form escondido do cancelamento: o ConfirmDialog só decide se ele é submetido -->
<form
	bind:this={cancelForm}
	method="POST"
	action="?/cancelPackage"
	class="hidden"
	use:enhance={() => {
		return async ({ update }) => {
			cancelling = null;
			await update();
		};
	}}
>
	<input type="hidden" name="package_id" value={cancelling?.id ?? ''} />
</form>

{#if cancelling}
	<ConfirmDialog
		title="Cancelar pacote"
		confirmLabel="Cancelar pacote"
		onConfirm={() => cancelForm?.requestSubmit()}
		onClose={() => (cancelling = null)}
	>
		As sessões <strong>futuras</strong> de <strong>{cancelling.nome}</strong> serão canceladas e
		liberadas da agenda. As já concluídas ou faltadas permanecem no histórico.
	</ConfirmDialog>
{/if}
