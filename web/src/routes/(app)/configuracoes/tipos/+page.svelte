<script lang="ts">
	import { enhance } from '$app/forms';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envioPorItem, reagirAoForm } from '$lib/forms.svelte';
	import Plus from '@lucide/svelte/icons/plus';
	import Pencil from '@lucide/svelte/icons/pencil';
	import Archive from '@lucide/svelte/icons/archive';
	import RotateCcw from '@lucide/svelte/icons/rotate-ccw';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import TypeModal from '$lib/components/appointment-types/TypeModal.svelte';
	import {
		canManageAppointmentTypes,
		iconComponent,
		splitByStatus,
		tint,
		type AppointmentType
	} from '$lib/appointment-types';
	import { toast } from '$lib/toast.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	// A lista é visível a todos os membros; só owner/admin veem as ações de gestão (T8 — a
	// policy da API é a autoridade; aqui é só UX). `me` vem do layout do shell.
	const canManage = $derived(canManageAppointmentTypes(data.me.papel));

	// Arquivado some da lista e vai para a seção recolhível (T5).
	const split = $derived(splitByStatus(data.appointmentTypes));

	let modal = $state<{ type: AppointmentType | null } | null>(null);

	// Arquivar/restaurar têm um form por linha, então o "em voo" é POR ITEM — um booleano só
	// giraria os botões da lista inteira.
	const linha = envioPorItem<string>();

	// Erro a exibir dentro do modal (quando o salvamento falhou).
	const modalError = $derived(
		modal && form && !form.ok && form.action === 'save' ? (form.error ?? null) : null
	);

	// Resultado de ação vira toast (protótipo :1030): sucesso sempre; erro só nas ações
	// disparadas fora de modal (arquivar/restaurar) — erro de salvamento aparece dentro do
	// próprio modal (modalError acima).
	reagirAoForm(
		() => form,
		{
			sucesso: (f) => toast(toastText(f.action)),
			erro: (f) => {
				if (f.error && (f.action === 'archive' || f.action === 'restore')) toast(f.error, 'error');
			}
		}
	);

	function toastText(action?: string): string {
		// "Tipo de atendimento salvo" é verbatim do protótipo (:1210). Arquivar/restaurar não
		// existem lá (T2/T5) e seguem o mesmo tom telegráfico.
		if (action === 'save') return 'Tipo de atendimento salvo';
		if (action === 'archive') return 'Tipo arquivado';
		if (action === 'restore') return 'Tipo restaurado';
		return 'Feito.';
	}
</script>

<svelte:head><title>Tipos de atendimento · Cinetra</title></svelte:head>

<!-- Linha da lista (:3230). Reusada nos ativos e nos arquivados: mesma anatomia, muda só a
     opacidade e o que fica à direita — restaurar no lugar de editar/arquivar. -->
{#snippet typeRow(t: AppointmentType, arquivado: boolean)}
	{@const Icon = iconComponent(t.icon)}
	<div
		class="flex items-center gap-[11px] border-t border-edge py-[9px] {arquivado
			? 'opacity-60'
			: ''}"
	>
		<span
			class="grid size-7.5 shrink-0 place-items-center rounded-controle"
			style="background:{tint(t.cor, 0.14)}"
		>
			<Icon size={16} color={t.cor} />
		</span>

		<div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-1.5 gap-y-1">
			<span class="truncate text-corpo font-semibold">{t.nome}</span>
			{#if t.grupo}
				<span
					class="shrink-0 rounded-micro bg-info-solid px-1.5 py-px text-micro font-bold text-on-solid"
				>
					grupo · cap {t.capacidade}
				</span>
			{/if}
		</div>

		<span class="shrink-0 font-mono text-meta text-muted">{t.duracao_minutos}min</span>

		{#if canManage}
			{#if arquivado}
				<form method="POST" action="?/restore" use:enhance={linha.submit(t.id)}>
					<input type="hidden" name="id" value={t.id} />
					<SubmitButton
						emVoo={linha.emVoo(t.id)}
						class="flex shrink-0 items-center gap-1.5 rounded-controle border border-edge bg-surface px-2.5 py-1.5 text-rotulo font-semibold text-accent-text hover:bg-surface-2 disabled:opacity-60"
					>
						<RotateCcw size={13} /> Restaurar
					</SubmitButton>
				</form>
			{:else}
				<button
					type="button"
					title="Editar"
					onclick={() => (modal = { type: t })}
					class="grid size-7.5 shrink-0 place-items-center rounded-controle border border-edge bg-surface text-muted hover:bg-surface-2"
				>
					<Pencil size={14} />
				</button>
				<!-- Arquivar é neutro, não uma lixeira vermelha: a ação é reversível (T9) e
				     não confirma nada (T6) — o protótipo também não confirmava (:1211). -->
				<form method="POST" action="?/archive" use:enhance={linha.submit(t.id)}>
					<input type="hidden" name="id" value={t.id} />
					<!-- `trocaConteudo`: botão só de ícone — o giro entra NO LUGAR do arquivo, senão o
					     botão de 30px teria dois glifos disputando o espaço. -->
					<SubmitButton
						emVoo={linha.emVoo(t.id)}
						trocaConteudo
						title="Arquivar"
						class="grid size-7.5 shrink-0 place-items-center rounded-controle border border-edge bg-surface text-muted hover:bg-surface-2 disabled:opacity-60"
					>
						<Archive size={14} />
					</SubmitButton>
				</form>
			{/if}
		{/if}
	</div>
{/snippet}

<div class="mx-auto max-w-[760px] px-4 py-4 md:px-6">
	<section class="mb-3 rounded-cartao border border-edge bg-surface p-4">
		<div class="mb-3 flex items-center justify-between gap-3">
			<h2 class="text-leitura font-semibold">Tipos de atendimento</h2>
			{#if canManage}
				<button
					type="button"
					onclick={() => (modal = { type: null })}
					class="flex shrink-0 items-center gap-[5px] rounded-controle border border-edge bg-surface px-[11px] py-1.5 text-rotulo font-semibold text-ink hover:bg-surface-2"
				>
					<Plus size={14} /> Novo tipo
				</button>
			{/if}
		</div>

		{#each split.ativos as t (t.id)}
			{@render typeRow(t, false)}
		{/each}

		{#if !split.ativos.length}
			<!-- Só acontece se arquivarem todos: a clínica nasce com os 5 do seed (T3). -->
			<p class="border-t border-edge py-3 text-rotulo text-muted">
				Nenhum tipo ativo — sem tipo não se agenda.
				{#if canManage}
					Crie um novo{split.arquivados.length ? ' ou restaure um arquivado abaixo' : ''}.
				{/if}
			</p>
		{/if}

		{#if split.arquivados.length}
			<!-- Seção "Arquivados" (T5): não existe no protótipo. <details> em vez de um toggle
			     com $state — nasce acessível e teclável sem JS nenhum. -->
			<details class="group mt-3 border-t border-edge pt-3">
				<summary
					class="flex cursor-pointer list-none items-center gap-1.5 text-rotulo font-semibold text-muted [&::-webkit-details-marker]:hidden"
				>
					<ChevronDown size={14} class="transition-transform group-open:rotate-180" />
					Arquivados ({split.arquivados.length})
				</summary>
				<div class="mt-1">
					{#each split.arquivados as t (t.id)}
						{@render typeRow(t, true)}
					{/each}
				</div>
			</details>
		{/if}
	</section>
</div>

{#if modal}
	<TypeModal
		type={modal.type}
		capacidadePadrao={data.capacidadePadrao}
		error={modalError}
		onClose={() => (modal = null)}
	/>
{/if}
