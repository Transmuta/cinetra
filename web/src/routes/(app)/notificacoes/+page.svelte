<script lang="ts">
	import { enhance } from '$app/forms';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envio, envioPorItem, reagirAoForm } from '$lib/forms.svelte';
	import { goto, invalidate } from '$app/navigation';
	import { page as pageState } from '$app/state';
	import { navigateQuery } from '$lib/querystring';
	import BellOff from '@lucide/svelte/icons/bell-off';
	import Check from '@lucide/svelte/icons/check';
	import CheckCheck from '@lucide/svelte/icons/check-check';
	import Paginacao from '$lib/components/Paginacao.svelte';
	import EstadoVazio from '$lib/components/EstadoVazio.svelte';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import { toast } from '$lib/toast.svelte';
	import { relativeTime, notificationHref, type AppNotification } from '$lib/notifications';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	const notifications = $derived(data.notifications);
	const unread = $derived(data.unread);
	const onlyUnread = $derived(data.onlyUnread);

	// As três actions sempre responderam `fail(…, { action, error })` — e esta tela era a única do
	// app que não declarava o `form`, então a mensagem chegava e morria aqui. "Limpar tudo" que
	// falha fechava o diálogo, deixava a lista igual e não dizia nada: do lado de quem clicou,
	// idêntico a uma caixa que já estava vazia.
	//
	// Só ERRO vira toast: o sucesso já se vê na tela (o realce sai, o contador cai, a lista
	// esvazia), e anunciar o óbvio seria ruído em cima de cada ✓ da lista.
	reagirAoForm(
		() => form,
		{ erro: (f) => toast(f.error ?? 'Não foi possível concluir a ação.', 'error') }
	);

	// Paginação (#54): `?page=` na URL, sem empilhar histórico — mesmo gesto da fila e de
	// Pacientes. Sem rodapé "X–Y de Z": a API não conta o total da caixa de propósito.
	function goPage(n: number) {
		navigateQuery('/notificacoes', pageState.url.searchParams, {
			page: n > 1 ? String(n) : null
		});
	}

	// O filtro Todas/Não lidas mora na SIDEBAR (`$lib/components/shell/Sidebar.svelte`), como em
	// Profissionais, Pacientes e Fila — não no corpo da tela. Aqui ele só é lido, para o estado
	// vazio saber qual vazio está mostrando. O `?page=` cai sozinho ao trocar de filtro, porque
	// os links da sidebar não o carregam.

	// Limpar é irreversível — não há lixeira, a linha some do banco. O diálogo é o único freio,
	// e o form escondido é o que ele dispara (molde do "sair de todos os dispositivos").
	let confirmingClear = $state(false);
	let clearForm: HTMLFormElement;

	// Marcar lida ao abrir: submete a action e, se a notificação tem destino, navega para lá.
	// Sem destino, só revalida (a linha perde o realce e o badge cai).
	//
	// O `invalidate('app:unread')` antes do `goto` NÃO é redundante — é o conserto de um bug
	// visto ao vivo: abrir uma notificação a marcava lida, mas o badge do sino só caía no F5.
	// O contador vem do load do LAYOUT, que declara `depends('app:unread')`; essa chave só cai
	// com um invalidate explícito, e navegar para `/agenda` não reexecuta o layout — é o mesmo
	// layout. Sem esta linha o número fica velho até a próxima recarga completa. O caminho de
	// baixo não precisa dele porque `update()` já invalida tudo.
	// "Ler todas" é um botão só; o ✓ de cada linha é um por item — daí os dois rastreadores.
	// Abrir a linha (`openRow`) fica de fora: aquilo NAVEGA, e um giro num link que já está
	// saindo da tela é ruído.
	const lerTodas = envio();
	const lerUma = envioPorItem<string>();

	function openRow(n: AppNotification) {
		return () =>
			async ({ result, update }: { result: { type: string }; update: () => Promise<void> }) => {
				const href = notificationHref(n);
				if (result.type === 'success' && href) {
					await invalidate('app:unread');
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
			<!-- `h2` (ACC-22): o `h1` é o do topbar, que já diz "Notificações". -->
			<h2 class="text-destaque leading-7 font-semibold text-ink">Notificações</h2>
			<p class="text-leitura leading-5 text-muted">
				{#if unread > 0}
					{unread} não {unread === 1 ? 'lida' : 'lidas'}
				{:else}
					Tudo em dia
				{/if}
			</p>
		</div>

		<div class="flex shrink-0 items-center gap-2">
			{#if unread > 0}
				<form method="POST" action="?/readAll" use:enhance={lerTodas.submit}>
					<SubmitButton
						emVoo={lerTodas.emVoo}
						class="inline-flex items-center gap-1.5 rounded-controle border border-edge bg-surface px-3 py-1.5 text-leitura leading-5 font-medium text-ink transition-colors hover:bg-surface-2 disabled:opacity-60"
					>
						<CheckCheck size={15} />
						Marcar todas como lidas
					</SubmitButton>
				</form>
			{/if}

			{#if notifications.length > 0}
				<button
					type="button"
					onclick={() => (confirmingClear = true)}
					class="inline-flex items-center gap-1.5 rounded-controle border border-edge bg-surface px-3 py-1.5 text-leitura leading-5 font-medium text-ink transition-colors hover:bg-surface-2 hover:text-danger"
				>
					<Trash2 size={15} />
					Limpar tudo
				</button>
			{/if}
		</div>
	</header>

	{#if notifications.length === 0}
		<!-- O vazio diz QUAL vazio: "Nenhuma notificação" com o filtro ligado faria quem tem a
		     caixa cheia de lidas achar que perdeu tudo. -->
		<EstadoVazio
			icone={BellOff}
			titulo={onlyUnread ? 'Nenhuma não lida' : 'Nenhuma notificação'}
		>
			{#snippet descricao()}
				{#if onlyUnread}
					<!-- "Todas" é o item da SIDEBAR, à esquerda — não uma aba. Dizer "aba" aqui mandava
					     a pessoa procurar um controle que não existe mais nesta tela. -->
					Tudo em dia por aqui. As já lidas continuam em "Todas", no menu ao lado.
				{:else}
					Avisamos aqui quando algo mudar na sua agenda, na fila ou na equipe.
				{/if}
			{/snippet}
		</EstadoVazio>
	{:else}
		<ul class="overflow-hidden rounded-cartao border border-edge bg-surface">
			{#each notifications as n (n.id)}
				<!-- Dois forms irmãos para a MESMA action, e não um botão dentro do outro (que é HTML
				     inválido): o grande abre a notificação, o de check só a marca lida. O realce da
				     não-lida subiu para o <li> para cobrir os dois. -->
				<li
					class="flex items-stretch border-b border-edge last:border-b-0 {n.read
						? ''
						: 'bg-accent-subtle/40'}"
				>
					<form method="POST" action="?/read" use:enhance={openRow(n)} class="min-w-0 flex-1">
						<input type="hidden" name="id" value={n.id} />
						<button
							type="submit"
							class="flex w-full items-start gap-3 px-4 py-3.5 text-left transition-colors hover:bg-surface-2"
						>
							<span
								class="mt-1.5 size-2 shrink-0 rounded-full {n.read ? 'bg-transparent' : 'bg-accent'}"
								aria-hidden="true"
							></span>
							<span class="min-w-0 flex-1">
								<span class="flex items-baseline justify-between gap-3">
									<span class="truncate text-leitura leading-5 font-semibold text-ink">{n.title}</span>
									<span class="shrink-0 text-rotulo leading-4 text-faint">{relativeTime(n.inserted_at)}</span>
								</span>
								<span class="mt-0.5 block text-leitura leading-5 text-muted">{n.body}</span>
							</span>
						</button>
					</form>

					<!-- Só para as não-lidas: numa já lida o botão não teria o que fazer. Sem callback
					     de enhance de propósito — o padrão do SvelteKit revalida tudo, e é o que faz o
					     realce sumir e o badge do sino cair sem sair da tela. -->
					{#if !n.read}
						<form
							method="POST"
							action="?/read"
							use:enhance={lerUma.submit(n.id)}
							class="flex shrink-0 items-center pr-3"
						>
							<!-- Em repouso já se lê como botão (borda + ícone no acento, não um cinza apagado);
							     no hover vira o acento sólido. Antes era `text-faint` sem borda, e ao vivo
							     passava por enfeite da linha. -->
							<SubmitButton
								emVoo={lerUma.emVoo(n.id)}
								trocaConteudo
								title="Marcar como lida"
								ariaLabel={'Marcar "' + n.title + '" como lida'}
								class="grid size-8 place-items-center rounded-controle border border-accent-border bg-surface text-accent-text transition-colors hover:border-accent hover:bg-accent hover:text-white disabled:opacity-60"
							>
								<Check size={16} />
							</SubmitButton>
						</form>
					{/if}
				</li>
			{/each}
		</ul>

		<!-- Sem rótulo "X–Y de Z": a API do sino não conta o total de propósito (contar obriga a
		     ler o recorte inteiro), e o `rotulo={null}` diz isso em voz alta. -->
		<Paginacao current={data.current} pageInfo={data.pageInfo} onPage={goPage} />
	{/if}

	<!-- Disparado pela confirmação. `use:enhance` padrão: o invalidateAll recarrega o layout, e é
	     por isso que o badge do sino cai junto com a lista. -->
	<form
		bind:this={clearForm}
		method="POST"
		action="?/clearAll"
		use:enhance={() => {
			return async ({ update }) => {
				confirmingClear = false;
				await update();
			};
		}}
		class="hidden"
	></form>
</div>

{#if confirmingClear}
	<ConfirmDialog
		title="Limpar notificações"
		confirmLabel="Apagar tudo"
		onClose={() => (confirmingClear = false)}
		onConfirm={() => clearForm.requestSubmit()}
	>
		Isto apaga <strong>todas as suas notificações</strong> desta clínica, lidas e não lidas, e
		não dá para desfazer. O que aconteceu continua na agenda e na trilha de auditoria.
	</ConfirmDialog>
{/if}
