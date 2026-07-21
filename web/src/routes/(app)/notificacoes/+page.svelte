<script lang="ts">
	import { enhance } from '$app/forms';
	import { goto } from '$app/navigation';
	import BellOff from '@lucide/svelte/icons/bell-off';
	import CheckCheck from '@lucide/svelte/icons/check-check';
	import { relativeTime, notificationHref, type AppNotification } from '$lib/notifications';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	const notifications = $derived(data.notifications);
	const unread = $derived(data.unread);

	// Marcar lida ao abrir: submete a action e, se a notificação tem destino, navega para lá.
	// Sem destino, só revalida (a linha perde o realce e o badge cai).
	function openRow(n: AppNotification) {
		return () =>
			async ({ result, update }: { result: { type: string }; update: () => Promise<void> }) => {
				const href = notificationHref(n.kind);
				if (result.type === 'success' && href) {
					await goto(href);
				} else {
					await update();
				}
			};
	}
</script>

<svelte:head><title>Notificações · Cinetra</title></svelte:head>

<div class="mx-auto w-full max-w-2xl px-4 py-6 sm:px-6">
	<header class="mb-5 flex items-center justify-between gap-4">
		<div>
			<h1 class="text-xl font-semibold text-ink">Notificações</h1>
			<p class="text-sm text-muted">
				{#if unread > 0}
					{unread} não {unread === 1 ? 'lida' : 'lidas'}
				{:else}
					Tudo em dia
				{/if}
			</p>
		</div>

		{#if unread > 0}
			<form method="POST" action="?/readAll" use:enhance>
				<button
					type="submit"
					class="inline-flex items-center gap-1.5 rounded-lg border border-edge bg-surface px-3 py-1.5 text-sm font-medium text-ink transition-colors hover:bg-surface-2"
				>
					<CheckCheck size={15} />
					Marcar todas como lidas
				</button>
			</form>
		{/if}
	</header>

	{#if notifications.length === 0}
		<div
			class="flex flex-col items-center justify-center rounded-xl border border-edge bg-surface py-16 text-center"
		>
			<BellOff size={28} class="text-faint" />
			<p class="mt-3 text-sm font-medium text-ink">Nenhuma notificação</p>
			<p class="mt-1 text-sm text-muted">
				Avisamos aqui quando algo mudar na sua agenda, na fila ou na equipe.
			</p>
		</div>
	{:else}
		<ul class="overflow-hidden rounded-xl border border-edge bg-surface">
			{#each notifications as n (n.id)}
				<li class="border-b border-edge last:border-b-0">
					<form method="POST" action="?/read" use:enhance={openRow(n)}>
						<input type="hidden" name="id" value={n.id} />
						<button
							type="submit"
							class="flex w-full items-start gap-3 px-4 py-3.5 text-left transition-colors hover:bg-surface-2 {n.read
								? ''
								: 'bg-teal-subtle/40'}"
						>
							<span
								class="mt-1.5 size-2 shrink-0 rounded-full {n.read ? 'bg-transparent' : 'bg-teal'}"
								aria-hidden="true"
							></span>
							<span class="min-w-0 flex-1">
								<span class="flex items-baseline justify-between gap-3">
									<span class="truncate text-sm font-semibold text-ink">{n.title}</span>
									<span class="shrink-0 text-xs text-faint">{relativeTime(n.inserted_at)}</span>
								</span>
								<span class="mt-0.5 block text-sm text-muted">{n.body}</span>
							</span>
						</button>
					</form>
				</li>
			{/each}
		</ul>
	{/if}
</div>
