<script lang="ts">
	// Caixa de notificações (doc 53). Os filtros saíram do corpo da página e vieram para cá, como
	// em Profissionais/Pacientes/Fila: `?filtro=nao-lidas` na URL, links e não botões.
	//
	// O número das não-lidas vem do LAYOUT (`unread`), que roda em toda navegação para alimentar o
	// badge do sino — não do load da página. Assim o sidebar e o sino nunca divergem. "Todas" fica
	// SEM número de propósito: a API não conta o total da caixa (`count: false`, custaria ler o
	// recorte inteiro a cada abertura). Mesma regra do `hasProfCounts` (F3, doc 34) — sem contagem
	// confiável, esconder é melhor do que exibir um número que conta só a página aberta.
	import { page } from '$app/state';
	import Inbox from '@lucide/svelte/icons/inbox';
	import BellDot from '@lucide/svelte/icons/bell-dot';
	import { notificationsHref, onlyUnreadFrom } from '$lib/notifications';

	const dados = $derived(page.data as { unread?: number });

	const notifUnread = $derived(dados.unread ?? 0);
	const notifOnlyUnread = $derived(onlyUnreadFrom(page.url.searchParams));
</script>

	<div class="flex-1 overflow-auto px-3 py-1">
		<div class="px-2 pb-1.5 pt-3 text-micro font-bold uppercase tracking-[.06em] text-faint">
			Filtrar
		</div>

		<a
			href={notificationsHref(false)}
			aria-current={!notifOnlyUnread ? 'page' : undefined}
			class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo {!notifOnlyUnread
				? 'bg-surface-2 font-semibold text-ink'
				: 'font-medium text-muted hover:bg-surface-2'}"
		>
			<span class={!notifOnlyUnread ? 'text-accent-text' : 'text-faint'}><Inbox size={15} /></span>
			<span class="flex-1 truncate">Todas</span>
		</a>

		<a
			href={notificationsHref(true)}
			aria-current={notifOnlyUnread ? 'page' : undefined}
			class="flex w-full items-center gap-2.5 rounded-controle px-2.5 py-[7px] text-corpo {notifOnlyUnread
				? 'bg-surface-2 font-semibold text-ink'
				: 'font-medium text-muted hover:bg-surface-2'}"
		>
			<span class={notifOnlyUnread ? 'text-accent-text' : 'text-faint'}><BellDot size={15} /></span>
			<span class="flex-1 truncate">Não lidas</span>
			{#if notifUnread > 0}
				<span class="font-mono text-meta text-faint">{notifUnread}</span>
			{/if}
		</a>
	</div>