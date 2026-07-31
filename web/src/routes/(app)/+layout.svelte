<script lang="ts">
	import { page } from '$app/state';
	import { afterNavigate, invalidate } from '$app/navigation';
	import { reportar } from '$lib/report';
	import Rail from '$lib/components/shell/Rail.svelte';
	import Sidebar from '$lib/components/shell/Sidebar.svelte';
	import Topbar from '$lib/components/shell/Topbar.svelte';
	import Toast from '$lib/components/Toast.svelte';
	import { aprisionarTab } from '$lib/dialogo';
	import { criarAnunciante } from '$lib/anuncio.svelte';
	import { activeMembership } from '$lib/session';
	import { connectNotifications } from '$lib/realtime';
	import { usarTokenRealtime } from '$lib/realtime-token.svelte';
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

	// ACC-08 (doc 83): esta gaveta é escrita à mão aqui e **não usa o shell `Drawer`**, então não
	// herdou nada do que o AN-08 consertou lá. Medido a 390px: ao abrir, o foco ficava no
	// hambúrguer e 1 Tab ia para o avatar do topbar — ou seja, para o fundo, nunca para dentro do
	// menu. O mesmo desenho dos outros dois shells: foca ao abrir, devolve ao fechar, aprisiona o
	// Tab enquanto está aberta.
	let gaveta = $state<HTMLElement>();

	$effect(() => {
		if (!drawerOpen) return;
		const antes = document.activeElement as HTMLElement | null;
		gaveta?.focus();
		return () => antes?.focus?.();
	});

	// ---- Tempo real do sino (doc 31 §5) -----------------------------------------------------
	// Uma conexão só para toda a sessão (o layout monta uma vez). Ao chegar `notification_created`,
	// revalida a contagem do badge e — se a tela `/notificacoes` estiver aberta — a lista dela.
	// O token vem do BFF; sem ele o badge ainda funciona por navegação (o load recarrega).
	// Falha aqui mata o TEMPO REAL de todo o app, o sino inclusive — o `usarTokenRealtime` reporta
	// em vez de engolir, que era o furo (doc 62 §7.2).
	const token = usarTokenRealtime();
	const realtime = $derived(token.cfg);

	// ACC-06 (doc 83): a notificação chegava e mudava só o badge do sino — nada era anunciado, e
	// para quem não vê a tela o app parecia estático. `criarAnunciante` cuida das duas armadilhas
	// (texto repetido não é mudança; rajada não pode virar uma fala por evento).
	const anunciante = criarAnunciante();

	$effect(() => {
		const cfg = realtime;
		if (!cfg) return;
		return connectNotifications(cfg, {
			onNotification: () => {
				void invalidate('app:unread');
				void invalidate('notificacoes:dados');
				anunciante.anunciar('Você recebeu uma notificação nova.');
			}
		});
	});

	$effect(() => () => anunciante.limpar());
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

<!--
	ACC-20 (doc 83): o rail tem ~10 destinos antes do conteúdo — medido, **13 Tabs** para o foco
	entrar no `<main>`. A landing já tinha o seu (`.cn-skip`); o app, não.

	Mora AQUI, fora e antes do `<div>` do shell, porque a ordem do DOM é a ordem do Tab: na primeira
	versão ele ficou dentro da coluna do conteúdo, depois do rail, e a sonda mediu 14 Tabs até o
	`<main>` — um Tab PIOR que antes, e o atalho inalcançável. Um skip link que não é o primeiro
	ponto de tabulação não serve para nada.

	`sr-only` até receber foco, e então aparece por cima de tudo. O `tabindex="-1"` no `<main>` é o
	que faz o pulo funcionar: sem ele o alvo não é focável e o browser move só a rolagem, deixando
	o foco do teclado onde estava.
-->
<a
	href="#conteudo"
	class="sr-only focus:not-sr-only focus:absolute focus:left-3 focus:top-3 focus:z-atalho focus:rounded-controle focus:bg-surface focus:px-3 focus:py-2 focus:text-corpo focus:font-semibold focus:text-ink focus:shadow-pop"
>
	Pular para o conteúdo
</a>

<div class="flex h-dvh w-full overflow-hidden bg-canvas text-ink">
	<!-- Desktop (≥lg): rail + sidebar fixos. -->
	<div class="hidden lg:flex">
		{@render cromo()}
	</div>

	<div class="flex min-w-0 flex-1 flex-col">
		<Topbar
			{pathname}
			{me}
			menuAberto={drawerOpen}
			onMenu={() => (drawerOpen = !drawerOpen)}
		/>
		<!--
			`relative` não é decoração: é o que impede o SEGUNDO scroll.

			O shell é `h-dvh overflow-hidden` e quem rola é este `<main>` — mas um descendente
			`position: absolute` sem ancestral posicionado tem o DOCUMENTO como bloco container, e
			então é colocado na coordenada de documento correspondente à sua posição estática lá no
			fim do conteúdo rolado. Ou seja: ele estica o documento e faz nascer uma barra de rolagem
			que leva rail, sidebar e topbar para fora da tela.

			Quem faz isso não é código de página, é o `.sr-only` do Tailwind (`position: absolute`),
			que a auditoria usa uma vez POR LINHA (a data por extenso ao lado da hora). Medido em
			`/auditoria`, viewport de 420px: documento com 1110px de altura. Com `relative` aqui, o
			bloco container passa a ser o próprio `main`, o texto oculto rola junto com a sua linha —
			que é o certo — e o documento volta a caber na tela.

			Fixado por `e2e/scroll-shell.spec.ts`. O teste é e2e porque jsdom não faz layout: em
			Vitest `scrollHeight` é sempre 0 e o bug passaria verde.
		-->
		<main id="conteudo" tabindex="-1" class="relative flex-1 overflow-auto focus:outline-none">
			{@render children()}
		</main>
	</div>
</div>

<!-- Toast global do shell (feedback de ações; $lib/toast.svelte.ts) -->
<Toast />

<!--
	Região de anúncio do TEMPO REAL (ACC-06). Invisível: o que ela diz já está na tela (o badge do
	sino) — ela existe para que a mudança também chegue a quem não a vê. Separada do Toast de
	propósito: aquele fala de ação de quem está usando; esta, de coisa que aconteceu sozinha.
-->
<p class="sr-only" role="status" aria-live="polite">{anunciante.texto()}</p>

<!-- Mobile (<lg): gaveta com rail + sidebar sobre um backdrop. -->
{#if drawerOpen}
	<div class="fixed inset-0 z-cobertura flex lg:hidden">
		<button
			type="button"
			aria-label="Fechar menu"
			class="absolute inset-0 bg-overlay"
			onclick={() => (drawerOpen = false)}
		></button>
		<!-- `role="dialog"` + `aria-modal` como nos shells `Modal`/`Drawer`: é a mesma coisa que
		     eles são, só escrita à mão porque aqui o conteúdo é o cromo inteiro. O `id` é o alvo do
		     `aria-controls` do hambúrguer. -->
		<div
			bind:this={gaveta}
			id="menu-navegacao"
			tabindex="-1"
			role="dialog"
			aria-modal="true"
			aria-label="Menu de navegação"
			class="relative flex h-full shadow-pop focus:outline-none"
			onkeydown={(e) => aprisionarTab(e, gaveta)}
		>
			{@render cromo()}
		</div>
	</div>
{/if}
