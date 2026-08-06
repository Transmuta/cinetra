<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	import { CONTROL_CLASS, CONTROL_PX, CONTROL_H } from '$lib/components/Field.svelte';
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import { envio } from '$lib/forms.svelte';
	import Circle from '@lucide/svelte/icons/circle';
	import Building2 from '@lucide/svelte/icons/building-2';
	import Check from '@lucide/svelte/icons/check';
	import LogOut from '@lucide/svelte/icons/log-out';
	import UserAvatar from '$lib/components/UserAvatar.svelte';
	import { ROLE_META } from '$lib/members';
	import { toast } from '$lib/toast.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	// `me` vem do layout do app (mesma fonte do menu do usuário). A tela não refaz /me.
	const me = $derived(data.me);

	// Rascunho local do nome (como as demais telas de edição): edita e só então salva.
	let nome = $state(untrack(() => data.me.user.nome));
	const dirty = $derived(nome.trim() !== me.user.nome);
	const podeSalvar = $derived(dirty && nome.trim() !== '');

	// `update` faz o invalidateAll padrão: recarrega o layout (novo /me) → o nome no menu do
	// usuário e no topo se atualiza. `reset: false` preserva o campo em caso de erro.
	const save = envio({
		reset: false,
		aoResponder: (result) => {
			if (result.type === 'success') {
				nome = me.user.nome;
				toast('Perfil atualizado');
			} else if (result.type === 'failure') {
				const message = result.data?.error;
				toast(typeof message === 'string' ? message : 'Não foi possível salvar.', 'error');
			}
		}
	});

	function discard() {
		nome = me.user.nome;
	}

	// "Sair de todos os dispositivos": confirmação destrutiva → submete o form escondido (POST,
	// navegação completa que redireciona para /entrar).
	let confirming = $state(false);
	let signOutAllForm: HTMLFormElement;

	const inputCls = `${CONTROL_CLASS} ${CONTROL_PX} ${CONTROL_H} w-full`;
</script>

<svelte:head><title>Meu perfil · Cinetra</title></svelte:head>

<div class="mx-auto w-full max-w-[760px] px-4 py-6 sm:px-6">
	<header class="mb-5 flex items-center gap-3.5">
		<UserAvatar nome={me.user.nome} url={me.user.avatar_url} class="size-12 text-titulo" />
		<div class="min-w-0">
			<!-- `h2` (ACC-22), como em /auditoria e /notificacoes: o `h1` da página é o do topbar,
			     que já diz "Meu perfil". Esta era a ÚNICA das 19 rotas com dois `h1` (doc 93 §B-5) —
			     e o segundo não acrescentava um nível, repetia um. As classes mandam no visual. -->
			<h2 class="truncate text-destaque leading-7 font-semibold text-ink">{me.user.nome}</h2>
			<p class="truncate text-leitura leading-5 text-muted">{me.user.email}</p>
		</div>
	</header>

	<!-- Nome de exibição -->
	<section class="mb-3 rounded-cartao border border-edge bg-surface p-4">
		<form method="POST" action="?/update" use:enhance={save.submit} class="space-y-4">
			<div>
				<label for="nome" class="mb-1 block text-rotulo font-medium text-muted">
					Nome <span class="text-danger">*</span>
				</label>
				<input
					id="nome"
					name="nome"
					bind:value={nome}
					maxlength="160"
					placeholder="Como você aparece no sistema"
					class={inputCls}
				/>
			</div>

			<div>
				<label for="email" class="mb-1 block text-rotulo font-medium text-muted">E-mail</label>
				<input id="email" value={me.user.email} disabled class="{inputCls} text-muted" />
				<p class="mt-1 text-rotulo text-faint">
					É o seu login. Para trocar, fale com o suporte.
				</p>
			</div>

			<div class="flex items-center gap-2.5 border-t border-edge pt-3.5">
				<div
					class="flex flex-1 items-center gap-1.5 text-rotulo {dirty
						? 'font-semibold text-warning'
						: 'text-faint'}"
				>
					{#if dirty}
						<Circle size={8} class="fill-warning text-warning" /> Alterações não salvas
					{:else}
						O nome aparece no menu do usuário e na agenda.
					{/if}
				</div>

				{#if dirty}
					<button
						type="button"
						onclick={discard}
						class="rounded-controle border border-edge bg-surface px-3.5 py-2 text-corpo font-semibold text-muted hover:bg-surface-2"
					>
						Descartar
					</button>
				{/if}

				<Button type="submit"
					emVoo={save.emVoo}
					disabled={!podeSalvar}
				>
					Salvar
				</Button>
			</div>
		</form>
	</section>

	<!-- Clínicas do usuário (espelho do menu; a troca de tenant fica no menu do usuário) -->
	<section class="mb-3 rounded-cartao border border-edge bg-surface p-4">
		<h2 class="mb-3 text-corpo font-semibold text-ink">Suas clínicas</h2>
		<ul class="space-y-1.5">
			{#each me.memberships as m (m.clinic_id)}
				{@const isActive = m.clinic_id === me.active_clinic_id}
				<li class="flex items-center gap-2.5">
					<span
						class="grid size-[26px] shrink-0 place-items-center rounded-controle bg-surface-2 text-faint"
					>
						<Building2 size={14} />
					</span>
					<span class="min-w-0 flex-1">
						<span class="block truncate text-corpo font-medium text-ink">
							{m.clinic_nome ?? 'Clínica'}
						</span>
						<span class="block text-meta text-faint">{ROLE_META[m.papel].label}</span>
					</span>
					{#if isActive}
						<span
							class="inline-flex items-center gap-1 rounded-full bg-accent-subtle px-2 py-0.5 text-meta font-semibold text-accent-text"
						>
							<Check size={12} /> Ativa
						</span>
					{/if}
				</li>
			{/each}
		</ul>
	</section>

	<!-- Sessão -->
	<section class="rounded-cartao border border-edge bg-surface p-4">
		<h2 class="text-corpo font-semibold text-ink">Sessão</h2>
		<div class="mt-2.5 flex items-center justify-between gap-4">
			<p class="text-rotulo text-muted">
				Encerra o acesso em todos os aparelhos onde você entrou, inclusive este.
			</p>
			<button
				type="button"
				onclick={() => (confirming = true)}
				class="inline-flex shrink-0 items-center gap-1.5 rounded-controle border border-danger/40 bg-surface px-3 py-2 text-corpo font-semibold text-danger hover:bg-danger/10"
			>
				<LogOut size={15} />
				Sair de todos os dispositivos
			</button>
		</div>
	</section>

	<!-- POST de navegação completa (redireciona para /entrar); disparado pela confirmação. -->
	<form
		bind:this={signOutAllForm}
		method="POST"
		action="/auth/sign-out-everywhere"
		class="hidden"
	></form>
</div>

{#if confirming}
	<ConfirmDialog
		title="Sair de todos os dispositivos"
		confirmLabel="Sair de tudo"
		onClose={() => (confirming = false)}
		onConfirm={() => signOutAllForm.requestSubmit()}
	>
		Isto encerra sua sessão em <strong>todos os dispositivos</strong>, inclusive este. Você
		precisará entrar de novo com um novo link de acesso.
	</ConfirmDialog>
{/if}
