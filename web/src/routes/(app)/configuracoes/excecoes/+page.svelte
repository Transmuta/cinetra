<script lang="ts">
	import { enhance } from '$app/forms';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envioPorItem, reagirAoForm } from '$lib/forms.svelte';
	import Clock from '@lucide/svelte/icons/clock';
	import CalendarOff from '@lucide/svelte/icons/calendar-off';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import ExceptionForm from '$lib/components/scheduling/ExceptionForm.svelte';
	import { canManageSchedule, formatDate, formatPeriods } from '$lib/scheduling';
	import { toast } from '$lib/toast.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	const canManage = $derived(canManageSchedule(data.me.papel));

	// Uma linha por exceção, então o "em voo" é POR ITEM: um booleano só giraria a lista inteira.
	const linha = envioPorItem<string>();

	// Erro do "Adicionar" vai para dentro do formulário; erro do excluir vira toast.
	const formError = $derived(form && !form.ok && form.action === 'add' ? (form.error ?? null) : null);

	reagirAoForm(
		() => form,
		{
			sucesso: (f) => toast(f.action === 'delete' ? 'Exceção removida' : 'Exceção adicionada'),
			erro: (f) => {
				if (f.error && f.action === 'delete') toast(f.error, 'error');
			}
		}
	);
</script>

<svelte:head><title>Exceções · Cinetra</title></svelte:head>

<div class="mx-auto max-w-[760px] px-4 py-4 md:px-6">
	<section class="mb-3 rounded-cartao border border-edge bg-surface p-4">
		<h2 class="mb-1 text-leitura font-semibold">Exceções da agenda</h2>
		<p class="mb-3 text-rotulo text-muted">
			Datas específicas que fogem ao horário normal: feche o dia inteiro ou defina um horário só
			para aquele dia.
		</p>

		{#if canManage}
			<ExceptionForm error={formError} />
		{/if}

		{#if data.exceptions.length === 0}
			<p class="border-t border-edge py-3 text-rotulo text-muted">
				Nenhuma exceção cadastrada.
			</p>
		{/if}

		{#each data.exceptions as exc (exc.id)}
			{@const isHorario = exc.tipo === 'horario'}
			<div class="flex items-center gap-3 border-t border-edge py-2.5">
				{#if isHorario}
					<Clock size={16} class="shrink-0 text-accent" />
				{:else}
					<CalendarOff size={16} class="shrink-0 text-danger" />
				{/if}

				<span class="w-[92px] shrink-0 font-mono text-meta">{formatDate(exc.data)}</span>

				<div class="min-w-0 flex-1">
					{#if exc.nome}
						<div class="truncate text-corpo font-medium">{exc.nome}</div>
					{/if}
					<div class="font-mono text-micro {isHorario ? 'text-accent-text' : 'text-danger'}">
						{isHorario ? formatPeriods(exc.periods) : 'Fechado o dia inteiro'}
					</div>
				</div>

				{#if canManage}
					<form method="POST" action="?/delete" use:enhance={linha.submit(exc.id)}>
						<input type="hidden" name="id" value={exc.id} />
						<SubmitButton
							emVoo={linha.emVoo(exc.id)}
							trocaConteudo
							title="Remover exceção"
							ariaLabel="Remover exceção"
							class="grid size-7.5 shrink-0 place-items-center rounded-controle border border-edge bg-surface text-danger hover:bg-surface-2 disabled:opacity-60"
						>
							<Trash2 size={14} />
						</SubmitButton>
					</form>
				{/if}
			</div>
		{/each}
	</section>
</div>
