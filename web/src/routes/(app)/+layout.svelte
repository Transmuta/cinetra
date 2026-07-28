<script lang="ts">
	import { page } from '$app/state';
	import { afterNavigate, invalidate } from '$app/navigation';
	import { reportar } from '$lib/report';
	import Rail from '$lib/components/shell/Rail.svelte';
	import Sidebar from '$lib/components/shell/Sidebar.svelte';
	import Topbar from '$lib/components/shell/Topbar.svelte';
	import Toast from '$lib/components/Toast.svelte';
	import { activeMembership } from '$lib/session';
	import { connectNotifications, type RealtimeConfig } from '$lib/realtime';
	import type { LayoutData } from './$types';

	let { data, children }: { data: LayoutData; children: import('svelte').Snippet } = $props();

	const me = $derived(data.me);
	const unread = $derived(data.unread ?? 0);
	const membership = $derived(activeMembership(me));
	// O papel na clínica ativa. O rail o usa para esconder a Auditoria de quem levaria 403 —
	// e precisa chegar nas DUAS instâncias do rail (desktop e gaveta mobile).
	const papel = $derived(me.papel ?? null);
	const clinicName = $derived(membership?.clinic_nome ?? null);
	const clinicCnpj = $derived(membership?.clinic_cnpj ?? null);
	const clinicEndereco = $derived(membership?.clinic_endereco ?? null);
	const pathname = $derived(page.url.pathname);
	const theme = $derived((page.data.theme as string | null) ?? null);

	// Abaixo de `lg`, rail+sidebar viram uma gaveta aberta pelo hambúrguer do topbar (o
	// espaço não comporta os 312px de cromo + conteúdo). Navegar fecha a gaveta.
	let drawerOpen = $state(false);
	afterNavigate(() => (drawerOpen = false));

	// ---- Tempo real do sino (doc 31 §5) -----------------------------------------------------
	// Uma conexão só para toda a sessão (o layout monta uma vez). Ao chegar `notification_created`,
	// revalida a contagem do badge e — se a tela `/notificacoes` estiver aberta — a lista dela.
	// O token vem do BFF; sem ele o badge ainda funciona por navegação (o load recarrega).
	let realtime = $state<RealtimeConfig | null>(null);

	$effect(() => {
		let vivo = true;
		fetch('/api/realtime/token')
			.then((r) => (r.ok ? r.json() : null))
			.then((cfg) => {
				if (vivo && cfg?.token) realtime = cfg as RealtimeConfig;
			})
			// Falha aqui mata o TEMPO REAL de todo o app (o sino de notificações inclusive), e antes
			// era invisível: sem token o socket nunca abre e não há console, log nem aviso em lugar
			// nenhum — só um badge que nunca mais muda (doc 62 §7.2).
			.catch((e) => reportar('realtime:token', e));
		return () => {
			vivo = false;
		};
	});

	$effect(() => {
		const cfg = realtime;
		if (!cfg) return;
		return connectNotifications(cfg, {
			onNotification: () => {
				void invalidate('app:unread');
				void invalidate('notificacoes:dados');
			}
		});
	});
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && (drawerOpen = false)} />

<!--
	O cromo (rail + sidebar) num SNIPPET, e não escrito duas vezes.

	Ele aparece em dois lugares — fixo no desktop e dentro da gaveta no mobile — e cada prop nova
	precisava ser ligada nos dois. Foi assim que o bug do CNPJ passou (props só na instância
	mobile), e o bate-volta mostrou que a fiação continuava desprotegida: apagar `{papel}` só da
	gaveta deixava a recepção vendo o ícone da Auditoria no menu do celular, com a suíte inteira
	verde (1445 testes) e o `svelte-check` limpo — o prop é opcional, então nada acusa.

	Um teste pegaria a mutação; o snippet **elimina a classe do bug**: não há mais dois lugares
	que possam divergir.
-->
{#snippet cromo()}
	<Rail {pathname} {theme} {unread} {papel} />
	<Sidebar {pathname} {clinicName} {clinicCnpj} {clinicEndereco} />
{/snippet}

<div class="flex h-dvh w-full overflow-hidden bg-canvas text-ink">
	<!-- Desktop (≥lg): rail + sidebar fixos. -->
	<div class="hidden lg:flex">
		{@render cromo()}
	</div>

	<div class="flex min-w-0 flex-1 flex-col">
		<Topbar {pathname} {me} onMenu={() => (drawerOpen = true)} />
		<main class="flex-1 overflow-auto">
			{@render children()}
		</main>
	</div>
</div>

<!-- Toast global do shell (feedback de ações; $lib/toast.svelte.ts) -->
<Toast />

<!-- Mobile (<lg): gaveta com rail + sidebar sobre um backdrop. -->
{#if drawerOpen}
	<div class="fixed inset-0 z-40 flex lg:hidden">
		<button
			type="button"
			aria-label="Fechar menu"
			class="absolute inset-0 bg-black/40"
			onclick={() => (drawerOpen = false)}
		></button>
		<div class="relative flex h-full shadow-pop">
			{@render cromo()}
		</div>
	</div>
{/if}
