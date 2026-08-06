<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import { envio as criarEnvio } from '$lib/forms.svelte';
	import Info from '@lucide/svelte/icons/info';
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import User from '@lucide/svelte/icons/user';
	import Field from '$lib/components/Field.svelte';
	import Modal from '$lib/components/Modal.svelte';
	import { INVITABLE_ROLES, ROLE_META, type Member, type Professional } from '$lib/members';
	import type { Papel } from '$lib/session';

	let {
		mode,
		member = null,
		professionals,
		onClose,
		error = null
	}: {
		mode: 'invite' | 'edit';
		member?: Member | null;
		professionals: Professional[];
		onClose: () => void;
		error?: string | null;
	} = $props();

	const editing = $derived(mode === 'edit');

	// Valor inicial vindo da prop: o modal é recriado a cada abertura (bloco {#if}), então
	// capturar só o valor inicial é o comportamento correto (daí o untrack).
	let papel = $state<Papel>(
		untrack(() => (member && INVITABLE_ROLES.includes(member.papel) ? member.papel : 'recepcao'))
	);
	let professionalId = $state(untrack(() => member?.professional_id ?? ''));

	const ROLE_ICONS: Record<Papel, typeof ShieldCheck> = {
		owner: ShieldCheck,
		admin: ShieldCheck,
		profissional: Stethoscope,
		recepcao: User
	};

	// `reset: false`: o erro volta para dentro do modal — limpar os campos junto apagaria o que
	// a pessoa precisa corrigir (ver `$lib/forms.svelte.ts`).
	const envio = criarEnvio({
		reset: false,
		aoResponder: (result) => {
			if (result.type === 'success') onClose();
		}
	});

	// Os botões do rodapé vivem fora do <form> (no snippet footer do shell) e se
	// associam a ele pelo atributo form= — assim o corpo rola e o rodapé fica.
	const formId = 'member-modal-form';
</script>

<Modal title={editing ? 'Editar membro' : 'Convidar membro'} {onClose} maxWidth="max-w-[500px]">
	<form id={formId} method="POST" action={editing ? '?/update' : '?/invite'} use:enhance={envio.submit}>
		{#if editing}
			<input type="hidden" name="id" value={member?.id} />
			<div class="mb-4 rounded-controle border border-edge bg-surface-2 px-3 py-2.5">
				<div class="text-corpo font-semibold">{member?.nome}</div>
				<div class="font-mono text-meta text-faint">{member?.email}</div>
			</div>
		{:else}
			<Field label="Nome" name="nome" placeholder="Nome completo" />
			<Field
				label="E-mail (para onde vai o convite)"
				name="email"
				type="email"
				placeholder="nome@clinica.com.br"
				required
			/>
		{/if}

		<div class="mb-2 text-rotulo font-semibold text-muted">Papel</div>
		<input type="hidden" name="papel" value={papel} />
		<div class="mb-1 flex flex-col gap-2">
			{#each INVITABLE_ROLES as role (role)}
				{@const Icon = ROLE_ICONS[role]}
				{@const on = papel === role}
				<button
					type="button"
					onclick={() => (papel = role)}
					aria-pressed={on}
					class="rounded-controle border p-3 text-left transition-colors {on
						? 'border-accent-border bg-accent-subtle'
						: 'border-edge bg-surface hover:bg-surface-2'}"
				>
					<div class="flex items-center gap-2 text-corpo font-semibold text-ink">
						<span class={on ? 'text-accent-text' : 'text-faint'}><Icon size={15} /></span>
						{ROLE_META[role].label}
					</div>
					<div class="mt-0.5 text-meta leading-snug text-muted">{ROLE_META[role].desc}</div>
				</button>
			{/each}
		</div>

		{#if papel === 'profissional'}
			<div class="mt-3 border-t border-edge pt-3">
				<label class="block">
					<span class="mb-[5px] block text-rotulo font-semibold text-muted">
						Vincular ao profissional
					</span>
					<select
						name="professional_id"
						bind:value={professionalId}
						class="h-[38px] w-full rounded-controle border border-edge-strong bg-surface px-[11px] text-corpo text-ink"
					>
						<option value="">Selecione um profissional…</option>
						{#each professionals as p (p.id)}
							<option value={p.id}>{p.nome}</option>
						{/each}
					</select>
				</label>
				{#if !professionalId}
					<div
						class="mt-2 flex items-start gap-2 rounded-controle bg-warning/10 px-3 py-2.5 text-rotulo text-warning"
					>
						<Info size={14} class="mt-0.5 shrink-0" />
						O papel Profissional exige um vínculo — escolha qual registro da agenda este acesso representa.
					</div>
				{/if}
			</div>
		{:else}
			<!-- ao salvar um não-profissional, limpa qualquer vínculo antigo. -->
			<input type="hidden" name="professional_id" value="" />
		{/if}

		{#if error}
			<p class="mt-3 text-rotulo font-medium text-danger">{error}</p>
		{/if}
	</form>

	{#snippet footer()}
		<button
			type="button"
			onclick={onClose}
			class="rounded-controle border border-edge bg-surface px-4 py-2.25 text-corpo font-semibold text-ink hover:bg-surface-2"
		>
			Cancelar
		</button>
		<Button type="submit"
			emVoo={envio.emVoo}
			form={formId}
			disabled={papel === 'profissional' && !professionalId}
		>
			{editing ? 'Salvar' : 'Enviar convite'}
		</Button>
	{/snippet}
</Modal>
