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
	import {
		linkedProfessionalName,
		professionalsWithoutAccess,
		type Member
	} from '$lib/members';
	import { initials } from '$lib/format';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	let modal = $state<{ mode: 'invite' | 'edit'; member: Member | null } | null>(null);

	const semAcesso = $derived(professionalsWithoutAccess(data));

	// Erro a exibir dentro do modal (quando o convite/edição falhou).
	const modalError = $derived(
		modal && form && !form.ok && form.action === (modal.mode === 'edit' ? 'update' : 'invite')
			? (form.error ?? null)
			: null
	);

	// Mensagem de topo (flash) por resultado de ação.
	const flash = $derived(
		form?.ok
			? { kind: 'ok' as const, text: flashText(form.action) }
			: form?.error
				? { kind: 'err' as const, text: form.error }
				: null
	);

	function flashText(action?: string): string {
		if (action === 'invite') return 'Convite enviado.';
		if (action === 'update') return 'Membro atualizado.';
		if (action === 'revoke') return 'Acesso removido.';
		if (action === 'resend') return 'Convite reenviado.';
		return 'Feito.';
	}

	const confirmRevoke: SubmitFunction = ({ cancel }) => {
		if (!confirm('Remover o acesso deste membro?')) cancel();
		return async ({ update }) => update();
	};
</script>

<svelte:head><title>Equipe & acessos · Movimento</title></svelte:head>

<div class="mx-auto max-w-[920px] px-4 py-4 md:px-6">
	{#if flash}
		<div
			role="status"
			class="mb-3 rounded-md border px-3 py-2 text-[13px] {flash.kind === 'ok'
				? 'border-teal-border bg-teal-subtle text-teal-text'
				: 'border-danger/40 bg-danger/10 text-danger'}"
		>
			{flash.text}
		</div>
	{/if}

	<!-- Membros da organização -->
	<section class="mb-3 rounded-lg border border-edge bg-surface p-4 shadow-card">
		<div class="mb-3.5 flex items-start justify-between gap-3">
			<div>
				<h2 class="text-[14px] font-semibold">Membros da organização</h2>
				<p class="mt-0.5 text-[12.5px] text-muted">
					Quem tem login e acesso ao sistema. Cada acesso tem um papel e, se for profissional, um
					vínculo com a agenda.
				</p>
			</div>
			<button
				type="button"
				onclick={() => (modal = { mode: 'invite', member: null })}
				class="flex shrink-0 items-center gap-1.5 rounded-md bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary hover:bg-primary-hover"
			>
				<UserPlus size={15} /> Convidar membro
			</button>
		</div>

		<!-- cabeçalho (desktop) -->
		<div
			class="hidden grid-cols-[2fr_1.3fr_1.3fr_auto] gap-2.5 px-1 pb-2 text-[11.5px] font-semibold text-faint md:grid"
		>
			<span>Membro</span><span>Papel e status</span><span>Vínculo</span><span></span>
		</div>

		{#each data.members as m (m.id)}
			{@const prof = linkedProfessionalName(m, data)}
			<div
				class="flex flex-col gap-2.5 border-t border-edge py-3 md:grid md:grid-cols-[2fr_1.3fr_1.3fr_auto] md:items-center md:gap-2.5"
			>
				<!-- identidade -->
				<span class="flex min-w-0 items-center gap-2.5">
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

				<!-- papel + status -->
				<span class="flex flex-col items-start gap-1.5">
					<RoleBadge papel={m.papel} />
					<StatusBadge status={m.status} />
				</span>

				<!-- vínculo -->
				<span class="text-[12.5px] text-muted">
					{#if m.papel !== 'profissional'}
						<span class="text-faint">—</span>
					{:else if prof}
						{prof}
					{:else}
						<span class="inline-flex items-center gap-1 font-semibold text-danger">
							<TriangleAlert size={13} /> Sem vínculo
						</span>
					{/if}
				</span>

				<!-- ações -->
				<span class="flex justify-start gap-1 md:justify-end">
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
					<form method="POST" action="?/revoke" use:enhance={confirmRevoke}>
						<input type="hidden" name="id" value={m.id} />
						<button
							type="submit"
							title="Remover acesso"
							class="grid size-8 place-items-center rounded-md border border-edge bg-surface text-danger hover:bg-surface-2"
						>
							<Trash2 size={14} />
						</button>
					</form>
				</span>
			</div>
		{/each}
	</section>

	<!-- Profissionais sem acesso -->
	{#if semAcesso.length}
		<section class="rounded-lg border border-edge bg-surface p-4 shadow-card">
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
