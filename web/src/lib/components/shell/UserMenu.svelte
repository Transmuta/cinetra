<script lang="ts">
	import User from '@lucide/svelte/icons/user';
	import Plus from '@lucide/svelte/icons/plus';
	import LogOut from '@lucide/svelte/icons/log-out';
	import Check from '@lucide/svelte/icons/check';
	import Building2 from '@lucide/svelte/icons/building-2';
	import UserAvatar from './UserAvatar.svelte';
	import { ROLE_META } from '$lib/members';
	import type { Me } from '$lib/session';

	// Menu do usuário. Ao clicar no avatar, abre um popover com perfil, troca de clínica, criar
	// nova e sair. `placement` posiciona o popover conforme onde o avatar mora:
	//  - 'topbar' (canto superior direito): abre para baixo, alinhado à direita;
	//  - 'rail'   (canto inferior esquerdo): abre para cima, à direita do rail.
	let { me, placement = 'topbar' }: { me: Me; placement?: 'topbar' | 'rail' } = $props();

	let open = $state(false);

	const popoverPos = $derived(
		placement === 'rail' ? 'bottom-0 left-full ml-2 origin-bottom-left' : 'right-0 top-full mt-2 origin-top-right'
	);

	function close() {
		open = false;
	}
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && close()} />

<div class="relative">
	{#if open}
		<!-- clique fora fecha o menu (backdrop invisível) -->
		<button
			type="button"
			aria-hidden="true"
			tabindex="-1"
			class="fixed inset-0 z-cobertura cursor-default"
			onclick={close}
		></button>
	{/if}

	<button
		type="button"
		onclick={() => (open = !open)}
		aria-haspopup="menu"
		aria-expanded={open}
		title={me.user.nome}
		class="rounded-full"
	>
		<UserAvatar nome={me.user.nome} url={me.user.avatar_url} class="size-[34px] text-rotulo" />
	</button>

	{#if open}
		<div
			class="absolute z-painel w-64 overflow-hidden rounded-controle border border-edge bg-surface text-ink shadow-pop {popoverPos}"
		>
			<!-- identidade -->
			<div class="border-b border-edge px-3.5 py-3">
				<div class="truncate text-corpo font-semibold">{me.user.nome}</div>
				<div class="truncate text-meta text-faint">{me.user.email}</div>
			</div>

			<!-- perfil -->
			<div class="p-1.5">
				<a
					href="/perfil"
					onclick={close}
					class="flex items-center gap-2.5 rounded-controle px-2.5 py-2 text-corpo font-medium text-muted hover:bg-surface-2 hover:text-ink"
				>
					<User size={15} class="text-faint" />
					Meu perfil
				</a>
			</div>

			<!-- clínicas: cada uma é um POST para trocar o tenant ativo (CSRF, como o sign-out) -->
			<div class="border-t border-edge p-1.5">
				<div
					class="px-2.5 pb-1 pt-1.5 text-micro font-bold uppercase tracking-[.06em] text-faint"
				>
					Clínicas
				</div>
				{#each me.memberships as m (m.clinic_id)}
					{@const isActive = m.clinic_id === me.active_clinic_id}
					<form method="POST" action="/auth/switch-clinic">
						<input type="hidden" name="clinic_id" value={m.clinic_id} />
						<button
							type="submit"
							disabled={isActive}
							aria-current={isActive ? 'true' : undefined}
							class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-2 text-left text-corpo {isActive
								? 'font-semibold text-ink'
								: 'font-medium text-muted hover:bg-surface-2 hover:text-ink'}"
						>
							<span class="grid size-[22px] shrink-0 place-items-center rounded-controle bg-surface-2 text-faint">
								<Building2 size={13} />
							</span>
							<span class="min-w-0 flex-1">
								<span class="block truncate">{m.clinic_nome ?? 'Clínica'}</span>
								<span class="block text-meta font-normal text-faint">{ROLE_META[m.papel].label}</span>
							</span>
							{#if isActive}<Check size={15} class="shrink-0 text-accent-text" />{/if}
						</button>
					</form>
				{/each}

				<a
					href="/comecar?nova=1"
					onclick={close}
					class="mt-0.5 flex items-center gap-2.5 rounded-controle px-2.5 py-2 text-corpo font-medium text-accent-text hover:bg-surface-2"
				>
					<span class="grid size-[22px] shrink-0 place-items-center rounded-controle bg-accent-subtle">
						<Plus size={14} />
					</span>
					Nova clínica
				</a>
			</div>

			<!-- sair: POST (proteção CSRF do SvelteKit, doc 13 causa E) -->
			<div class="border-t border-edge p-1.5">
				<form method="POST" action="/auth/sign-out">
					<button
						type="submit"
						class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-2 text-left text-corpo font-medium text-muted hover:bg-surface-2 hover:text-ink"
					>
						<LogOut size={15} class="text-faint" />
						Sair
					</button>
				</form>
			</div>
		</div>
	{/if}
</div>
