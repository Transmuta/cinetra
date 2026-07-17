<script lang="ts">
	import { enhance } from '$app/forms';
	import type { SubmitFunction } from '@sveltejs/kit';
	import UserPlus from '@lucide/svelte/icons/user-plus';
	import Pencil from '@lucide/svelte/icons/pencil';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import Send from '@lucide/svelte/icons/send';
	import KeyRound from '@lucide/svelte/icons/key-round';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import RoleBadge from '$lib/components/members/RoleBadge.svelte';
	import StatusBadge from '$lib/components/members/StatusBadge.svelte';
	import MemberModal from '$lib/components/members/MemberModal.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import {
		linkedProfessionalName,
		professionalsWithoutAccess,
		canManageMember,
		type Member
	} from '$lib/members';
	import { canManageMembers } from '$lib/session';
	import { initials } from '$lib/format';
	import { toast } from '$lib/toast.svelte';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	// A lista é visível a todos os membros; só owner/admin veem as ações de gestão (a policy
	// da API é a autoridade — aqui é só UX). `me` vem do layout do shell (app)/+layout.server.
	const canManage = $derived(canManageMembers(data.me.papel));

	let modal = $state<{ mode: 'invite' | 'edit'; member: Member | null } | null>(null);

	const semAcesso = $derived(professionalsWithoutAccess(data));

	// Erro a exibir dentro do modal (quando o convite/edição falhou).
	const modalError = $derived(
		modal && form && !form.ok && form.action === (modal.mode === 'edit' ? 'update' : 'invite')
			? (form.error ?? null)
			: null
	);

	// Resultado de ação vira toast (protótipo :1030): sucesso sempre; erro só nas ações
	// disparadas fora de modal (revoke/resend) — erro de convite/edição aparece dentro
	// do próprio modal (modalError acima).
	$effect(() => {
		if (!form) return;
		if (form.ok) toast(toastText(form.action));
		else if (form.error && (form.action === 'revoke' || form.action === 'resend'))
			toast(form.error, 'error');
	});

	function toastText(action?: string): string {
		if (action === 'invite') return 'Convite enviado.';
		if (action === 'update') return 'Membro atualizado.';
		if (action === 'revoke') return 'Acesso removido.';
		if (action === 'resend') return 'Convite reenviado.';
		return 'Feito.';
	}

	// Remoção de acesso confirma num modal fiel ao protótipo (não no confirm() nativo).
	// O POST sai de um form escondido, submetido quando o usuário confirma.
	let revoking = $state<Member | null>(null);
	let revokeForm: HTMLFormElement | undefined;
	let revokeSubmitting = $state(false);

	const revokeSubmit: SubmitFunction = () => {
		revokeSubmitting = true;
		return async ({ update }) => {
			revokeSubmitting = false;
			revoking = null;
			await update();
		};
	};
</script>

<svelte:head><title>Equipe & acessos · Movimento</title></svelte:head>

<!-- Ações da linha (reusadas no card mobile e na grade desktop). -->
{#snippet rowActions(m: Member)}
	{#if m.status === 'pendente'}
		<form method="POST" action="?/resend" use:enhance>
			<input type="hidden" name="email" value={m.email} />
			<button
				type="submit"
				title="Reenviar convite"
				class="grid size-8 place-items-center rounded-md border border-edge bg-surface text-muted hover:bg-surface-2"
			>
				<Send size={14} />
			</button>
		</form>
	{/if}
	<button
		type="button"
		title="Editar"
		onclick={() => (modal = { mode: 'edit', member: m })}
		class="grid size-8 place-items-center rounded-md border border-edge bg-surface text-muted hover:bg-surface-2"
	>
		<Pencil size={14} />
	</button>
	<button
		type="button"
		title="Remover acesso"
		onclick={() => (revoking = m)}
		class="grid size-8 place-items-center rounded-md border border-edge bg-surface text-danger hover:bg-surface-2"
	>
		<Trash2 size={14} />
	</button>
{/snippet}

<div class="mx-auto max-w-[920px] px-4 py-4 md:px-6">
	<!-- Membros da organização -->
	<section class="mb-3 rounded-lg border border-edge bg-surface p-4">
		<div class="mb-3.5 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
			<div class="min-w-0">
				<h2 class="text-[14px] font-semibold">Membros da organização</h2>
				<p class="mt-0.5 text-[12.5px] text-muted">
					Quem tem login e acesso ao sistema. Cada acesso tem um papel e, se for profissional, um
					vínculo com a agenda.
				</p>
			</div>
			{#if canManage}
				<button
					type="button"
					onclick={() => (modal = { mode: 'invite', member: null })}
					class="flex w-full items-center justify-center gap-1.5 rounded-md bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary hover:bg-primary-hover sm:w-auto sm:shrink-0"
				>
					<UserPlus size={15} /> Convidar membro
				</button>
			{/if}
		</div>

		<!-- cabeçalho (desktop). A coluna de ações é FIXA (112px) — se fosse `auto`, o cabeçalho
		     (sem botões) e as linhas (2 ou 3 botões) resolveriam os `fr` sobre larguras diferentes
		     e as colunas sairiam do lugar. Padding horizontal igual ao das linhas. -->
		<div
			class="hidden grid-cols-[minmax(0,2fr)_minmax(0,1.3fr)_minmax(0,1.3fr)_112px] gap-2.5 px-1 pb-2 text-[11.5px] font-semibold text-faint md:grid"
		>
			<span>Membro</span><span>Papel</span><span>Vínculo</span><span></span>
		</div>

		{#each data.members as m (m.id)}
			{@const prof = linkedProfessionalName(m, data)}
			{@const canManageRow = canManageMember(data.me.papel, m)}
			<!-- <md: card empilhado; ≥md: grade de 4 colunas (mesmas trilhas do cabeçalho). -->
			<div
				class="flex flex-col gap-2.5 border-t border-edge py-3 md:grid md:grid-cols-[minmax(0,2fr)_minmax(0,1.3fr)_minmax(0,1.3fr)_112px] md:items-center md:gap-2.5 md:px-1"
			>
				<!-- identidade (com as ações à direita no mobile) -->
				<div class="flex items-center gap-2.5">
					<span class="flex min-w-0 flex-1 items-center gap-2.5">
						<span
							class="grid size-8 shrink-0 place-items-center rounded-full bg-surface-2 text-[11px] font-bold text-muted"
						>
							{initials(m.nome)}
						</span>
						<span class="min-w-0">
							<span class="block truncate text-[13.5px] font-semibold">{m.nome}</span>
							<span class="block truncate font-mono text-[11.5px] text-faint">{m.email}</span>
						</span>
					</span>
					{#if canManageRow}
						<span class="flex shrink-0 gap-1 md:hidden">{@render rowActions(m)}</span>
					{/if}
				</div>

				<!-- papel (status "Ativo" é o padrão e fica implícito; só sinalizamos o convite pendente) -->
				<span
					class="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1.5 md:flex-col md:items-start md:gap-1.5"
				>
					<RoleBadge papel={m.papel} />
					{#if m.status === 'pendente'}
						<StatusBadge status={m.status} />
					{/if}
				</span>

				<!-- vínculo (no mobile, oculto quando não há vínculo a mostrar) -->
				<span
					class="min-w-0 items-center gap-1.5 text-[12.5px] text-muted {m.papel === 'profissional'
						? 'flex'
						: 'hidden md:flex'}"
				>
					{#if m.papel !== 'profissional'}
						<span class="text-faint">—</span>
					{:else}
						<span class="shrink-0 text-faint md:hidden">Vínculo:</span>
						{#if prof}
							<span class="truncate">{prof}</span>
						{:else}
							<span class="inline-flex items-center gap-1 font-semibold text-danger">
								<TriangleAlert size={13} /> Sem vínculo
							</span>
						{/if}
					{/if}
				</span>

				<!-- ações (desktop) — só quando o actor pode gerenciar este membro -->
				{#if canManageRow}
					<span class="hidden justify-end gap-1 md:flex">{@render rowActions(m)}</span>
				{:else}
					<span class="hidden md:block"></span>
				{/if}
			</div>
		{/each}
	</section>

	<!-- Profissionais sem acesso (conceder acesso é gestão → só owner/admin) -->
	{#if canManage && semAcesso.length}
		<section class="rounded-lg border border-edge bg-surface p-4">
			<div class="mb-1 flex items-center gap-2">
				<KeyRound size={15} class="text-faint" />
				<h2 class="text-[14px] font-semibold">Profissionais sem acesso</h2>
			</div>
			<p class="mb-3 text-[12.5px] text-muted">
				Trabalham na clínica mas não fazem login. Conceda acesso quando precisarem gerenciar a
				própria agenda.
			</p>
			{#each semAcesso as p (p.id)}
				<div class="flex items-center gap-2.5 border-t border-edge py-2.5">
					<span
						class="grid size-7 shrink-0 place-items-center rounded-full bg-surface-2 text-[10px] font-bold text-muted"
					>
						{initials(p.nome)}
					</span>
					<div class="min-w-0 flex-1 truncate text-[13px] font-semibold">{p.nome}</div>
					<button
						type="button"
						onclick={() =>
							(modal = {
								mode: 'invite',
								member: {
									id: '',
									nome: p.nome,
									email: '',
									papel: 'profissional',
									status: 'pendente',
									professional_id: p.id
								}
							})}
						class="flex shrink-0 items-center gap-1.5 rounded-md border border-edge bg-surface px-2.5 py-1.5 text-[12px] font-semibold text-teal-text hover:bg-surface-2"
					>
						<UserPlus size={13} /> Conceder acesso
					</button>
				</div>
			{/each}
		</section>
	{/if}
</div>

{#if modal}
	<MemberModal
		mode={modal.mode}
		member={modal.member}
		professionals={data.professionals}
		error={modalError}
		onClose={() => (modal = null)}
	/>
{/if}

<!-- form escondido do revoke: o ConfirmDialog só decide se ele é submetido -->
<form
	bind:this={revokeForm}
	method="POST"
	action="?/revoke"
	use:enhance={revokeSubmit}
	class="hidden"
>
	<input type="hidden" name="id" value={revoking?.id ?? ''} />
</form>

{#if revoking}
	<ConfirmDialog
		title="Remover acesso"
		confirmLabel="Remover acesso"
		submitting={revokeSubmitting}
		onConfirm={() => revokeForm?.requestSubmit()}
		onClose={() => (revoking = null)}
	>
		Remover o acesso de <strong>{revoking.nome}</strong>? A pessoa não vai mais conseguir entrar
		nesta clínica. Dá para convidar de novo quando quiser.
	</ConfirmDialog>
{/if}
