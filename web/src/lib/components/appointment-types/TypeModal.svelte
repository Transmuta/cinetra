<script lang="ts">
	// Modal de tipo de atendimento, fiel ao modalTipo do protótipo (:2388): 480px, nome +
	// grid [duração | cor], paleta de ícones, checkbox de grupo e capacidade condicional.
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envio as criarEnvio } from '$lib/forms.svelte';
	import Field from '$lib/components/Field.svelte';
	import Modal from '$lib/components/Modal.svelte';
	import {
		DEFAULT_COR,
		DEFAULT_DURACAO,
		DEFAULT_ICON,
		TYPE_COLORS,
		TYPE_ICONS,
		iconComponent,
		type AppointmentType
	} from '$lib/appointment-types';

	let {
		type = null,
		capacidadePadrao,
		onClose,
		error = null
	}: {
		/** null = novo tipo */
		type?: AppointmentType | null;
		/** default do campo de capacidade — `cap_turma_padrao` da clínica (doc 20 §1) */
		capacidadePadrao: number;
		onClose: () => void;
		error?: string | null;
	} = $props();

	const editing = $derived(type !== null);

	// Valores iniciais vindos da prop: o modal é recriado a cada abertura (bloco {#if}), então
	// capturar só o valor inicial é o comportamento correto (daí o untrack).
	let nome = $state(untrack(() => type?.nome ?? ''));
	let cor = $state(untrack(() => type?.cor ?? DEFAULT_COR));
	let icon = $state(untrack(() => type?.icon ?? DEFAULT_ICON));
	let grupo = $state(untrack(() => type?.grupo ?? false));

	// Os numéricos não precisam de binding: quem submete o valor é o próprio input (name=),
	// e ninguém aqui lê de volta. Só o `nome` é reativo — é ele que libera o Salvar.
	const duracaoInicial = untrack(() => type?.duracao_minutos ?? DEFAULT_DURACAO);
	const capacidadeInicial = untrack(() => type?.capacidade ?? capacidadePadrao);

	// `reset: false`: o erro volta para dentro do modal, e limpar os campos junto apagaria o que
	// a pessoa precisa corrigir (ver `$lib/forms.svelte.ts`).
	const envio = criarEnvio({
		reset: false,
		aoResponder: (result) => {
			if (result.type === 'success') onClose();
		}
	});

	// Os botões do rodapé vivem fora do <form> (no snippet footer do shell) e se associam a
	// ele pelo atributo form= — assim o corpo rola e o rodapé fica.
	const formId = 'type-modal-form';
</script>

<Modal
	title={editing ? 'Editar tipo' : 'Novo tipo de atendimento'}
	{onClose}
	maxWidth="max-w-[480px]"
>
	<form id={formId} method="POST" action="?/save" use:enhance={envio.submit}>
		{#if type}
			<input type="hidden" name="id" value={type.id} />
		{/if}

		<Field label="Nome" name="nome" bind:value={nome} placeholder="Ex.: Sessão" />

		<!-- grid 1fr 1fr (:2395): duração à esquerda, swatches de cor à direita -->
		<div class="grid grid-cols-2 gap-[10px]">
			<Field
				label="Duração (min)"
				name="duracao_minutos"
				type="number"
				min={10}
				step={5}
				mono
				value={String(duracaoInicial)}
			/>

			<Field label="Cor">
				<div class="flex flex-wrap gap-1.5">
					{#each TYPE_COLORS as col (col)}
						<button
							type="button"
							onclick={() => (cor = col)}
							aria-label="Cor {col}"
							aria-pressed={cor === col}
							style="background:{col}"
							class="size-7 rounded-[7px] border-[3px] {cor === col
								? 'border-ink'
								: 'border-transparent'}"
						></button>
					{/each}
				</div>
			</Field>
		</div>
		<input type="hidden" name="cor" value={cor} />

		<Field label="Ícone">
			<div class="flex flex-wrap gap-1.5">
				{#each TYPE_ICONS as ic (ic)}
					{@const Icon = iconComponent(ic)}
					{@const on = icon === ic}
					<button
						type="button"
						onclick={() => (icon = ic)}
						aria-label="Ícone {ic}"
						aria-pressed={on}
						class="grid size-8.5 place-items-center rounded-[7px] border {on
							? 'border-teal-border bg-teal-subtle text-teal-text'
							: 'border-edge bg-surface text-muted hover:bg-surface-2'}"
					>
						<Icon size={16} />
					</button>
				{/each}
			</div>
		</Field>
		<input type="hidden" name="icon" value={icon} />

		<label class="mb-2.5 flex cursor-pointer items-center gap-2 text-[13px]">
			<input type="checkbox" bind:checked={grupo} class="size-4 accent-teal" />
			Atendimento em grupo
		</label>
		<!-- checkbox desmarcado não é submetido; o valor viaja neste hidden. -->
		<input type="hidden" name="grupo" value={grupo} />

		{#if grupo}
			<Field
				label="Capacidade do grupo"
				name="capacidade"
				type="number"
				min={2}
				mono
				width="w-[120px]"
				value={String(capacidadeInicial)}
			/>
		{/if}

		{#if error}
			<p class="mt-3 text-[12.5px] font-medium text-danger">{error}</p>
		{/if}
	</form>

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-md border border-edge bg-surface px-4 py-2.25 text-[13.5px] font-semibold text-ink hover:bg-surface-2"
		>
			Cancelar
		</button>
		<SubmitButton
			emVoo={envio.emVoo}
			form={formId}
			disabled={nome.trim() === ''}
			class="inline-flex items-center gap-1.5 rounded-md bg-primary px-4 py-2.25 text-[13.5px] font-semibold text-on-primary hover:bg-primary-hover disabled:opacity-60"
		>
			Salvar
		</SubmitButton>
	{/snippet}
</Modal>
