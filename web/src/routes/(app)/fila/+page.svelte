<script lang="ts">
	// Fila de espera (doc 25, Entrega 5). Lista de pacientes aguardando encaixe — ordenada,
	// filtrada (`?prio=`) e paginada NO SERVIDOR desde o F6; aqui não se reordena nada. Três
	// modais: adicionar/editar (AddToWaitlistModal), oferecer vaga (OfferSlotModal) e a confirmação
	// de remover (ConfirmDialog). O "Adicionar à fila" mora na sidebar e viaja por `?novo=1` —
	// o único gatilho que precisa cruzar de um componente (a sidebar) para a página.
	import { invalidate, invalidateAll } from '$app/navigation';
	import { deserialize } from '$app/forms';
	import { page as pageState } from '$app/state';
	import { navigateQuery, type QueryPatch } from '$lib/querystring';
	import {
		connectWaitlist,
		type RealtimeConfig,
		type WaitlistConnection
	} from '$lib/realtime';
	import Plus from '@lucide/svelte/icons/plus';
	import Pencil from '@lucide/svelte/icons/pencil';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import AddToWaitlistModal from '$lib/components/fila/AddToWaitlistModal.svelte';
	import OfferSlotModal from '$lib/components/fila/OfferSlotModal.svelte';
	import PriorityBadge from '$lib/components/fila/PriorityBadge.svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import { toast } from '$lib/toast.svelte';
	import { initials } from '$lib/format';
	import { avatarColor } from '$lib/avatar';
	import { stripTitle } from '$lib/patients';
	import {
		canManageWaitlist,
		dispItems,
		slotDateLabel,
		type Entry,
		type Slot,
	} from '$lib/waitlist';
	import { m2t, type SearchResult } from '$lib/agenda';
	import Radio from '@lucide/svelte/icons/radio';
	import { pageLabel } from '$lib/pagination';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import type { ActionResult } from '@sveltejs/kit';
	import type { PageData } from './$types';

	let { data, form }: { data: PageData; form: Record<string, unknown> | null } = $props();

	// Todo membro administra a fila (A8) — inclusive profissional; a autoridade real é a policy.
	const canManage = $derived(canManageWaitlist(data.me?.papel));

	// A lista chega do servidor já FILTRADA (`?prio=`), ORDENADA (prioridade → tempo de espera) e
	// PAGINADA (F6). Nada disso acontece aqui: filtrar ou reordenar a página no cliente seria
	// aplicar a regra a um recorte arbitrário — e o rodapé "X–Y de Z" passaria a contar outra
	// coisa que a tela mostra.
	const list = $derived(data.waitlist);

	const nameById = $derived(Object.fromEntries(data.professionals.map((p) => [p.id, p.nome])));

	// Cor do avatar = a do 1º profissional preferido (protótipo `profColor(firstProf||'p1')`).
	function entryColor(entry: Entry): string {
		const first = data.professionals.find((p) => p.id === entry.professional_ids[0]);
		return avatarColor(first?.cor_indice ?? 1);
	}

	function profNames(entry: Entry): string {
		if (!entry.professional_ids.length) return 'Qualquer';
		const nomes = entry.professional_ids
			.map((id) => nameById[id])
			.filter((n): n is string => !!n)
			.map(stripTitle);
		return nomes.length ? nomes.join(', ') : 'Qualquer';
	}

	// ---- Modais -----------------------------------------------------------------------------
	// Adicionar viaja por `?novo=1` (o gatilho vem da sidebar). Editar/oferecer/remover são da
	// própria página (botões de linha), então vivem em estado local.
	const showAdd = $derived(canManage && pageState.url.searchParams.has('novo'));
	let editing = $state<Entry | null>(null);
	let offering = $state<Entry | null>(null);
	// A vaga pré-escolhida ao clicar num chip de vaga casada — o modal abre já no passo de conversão
	// (o `offerVaga(f,slot)` do protótipo :2597). Nulo = abriu pelo botão "Oferecer" (lista de vagas).
	let preselecting = $state<Slot | null>(null);
	let removing = $state<Entry | null>(null);
	let removingBusy = $state(false);

	function openOffer(entry: Entry, slot: Slot | null = null) {
		preselecting = slot;
		offering = entry;
	}
	function closeOffer() {
		offering = null;
		preselecting = null;
	}

	// Aplica um patch na query string e navega (`$lib/querystring`). Usado para fechar o modal de
	// adicionar (limpar `?novo`), sem empilhar histórico.
	function navigate(patch: QueryPatch) {
		navigateQuery('/fila', pageState.url.searchParams, patch);
	}

	// Paginação (F6): `?page=` na URL, sem empilhar histórico — mesmo gesto da lista de Pacientes.
	function goPage(n: number) {
		navigate({ page: n > 1 ? String(n) : null });
	}

	const navBtn =
		'inline-flex items-center gap-1 rounded-lg border border-edge bg-surface px-2.5 py-1.5 text-[12.5px] font-semibold text-ink hover:bg-surface-2 disabled:opacity-40 disabled:hover:bg-surface';

	async function search(q: string): Promise<SearchResult> {
		const res = await fetch(`/fila/pacientes?q=${encodeURIComponent(q)}`);
		if (!res.ok) return { patients: [], total: 0 };
		return (await res.json()) as SearchResult;
	}

	// ---- Vagas (camada "quem cabe" / motor find_slots em lote) ------------------------------
	// A lista carrega SEM as vagas (o load não chama o motor); logo após, um GET em lote
	// (`/fila/slots`) enriquece cada linha com o estado "tem vaga". Reexecuta sempre que a fila
	// muda (edição, remoção, tempo real) — depende da identidade de `data.waitlist`, que o load
	// renova a cada reexecução. A falha degrada para o mapa vazio: a linha só não mostra a vaga.
	let slotsByEntry = $state<Record<string, Slot[]>>({});

	$effect(() => {
		void data.waitlist; // redispara ao recarregar a fila
		let vivo = true;
		// A MESMA janela da fila (F6) — inclusive o FILTRO: pedir vagas sem ele faz o motor
		// calcular para outro recorte, e a linha filtrada aparece sem chip de vaga.
		fetch(
			`/fila/slots?limit=${data.pageInfo.limit}&offset=${data.pageInfo.offset}` +
				(data.prio === 'todas' ? '' : `&prio=${data.prio}`)
		)
			.then((r) => (r.ok ? r.json() : { slots_by_entry: {} }))
			.then((d: { slots_by_entry?: Record<string, Slot[]> }) => {
				if (vivo) slotsByEntry = d.slots_by_entry ?? {};
			})
			.catch(() => {});
		return () => {
			vivo = false;
		};
	});

	function slotsFor(entry: Entry): Slot[] {
		return slotsByEntry[entry.id] ?? [];
	}

	// ---- Tempo real (D-E5.3) ----------------------------------------------------------------
	// O sinal `waitlist_changed` do canal recarrega a lista — a fila não é recortada por papel,
	// então não há bloco para remendar (é o mesmo desenho do sinal do Mês). O token vem do BFF,
	// uma vez por aba; sem ele a fila continua funcionando, só não atualiza sozinha.
	let realtime = $state<RealtimeConfig | null>(null);

	$effect(() => {
		let vivo = true;
		fetch('/api/realtime/token')
			.then((r) => (r.ok ? r.json() : null))
			.then((cfg) => {
				if (vivo && cfg?.token) realtime = cfg as RealtimeConfig;
			})
			.catch(() => {});
		return () => {
			vivo = false;
		};
	});

	// Coalescida: uma rajada (recepção mexendo em vários itens) vira UMA recarga. A leitura da
	// fila é barata, mas recarregar a cada evento de uma rajada é churn à toa.
	let recarga: ReturnType<typeof setTimeout> | null = null;
	function recarregar() {
		if (recarga) clearTimeout(recarga);
		recarga = setTimeout(() => {
			recarga = null;
			void invalidate('fila:dados');
		}, 400);
	}

	// Quem está oferecendo o quê, agora (doc 39): `entry_id → nomes`, já sem o próprio usuário.
	// É presença, não reserva — não trava nada e some quando a aba morre.
	let oferecendo = $state<Record<string, string[]>>({});
	let conexao = $state<WaitlistConnection | null>(null);

	// A fila tem UM tópico só, que nunca muda — então o efeito depende só de `realtime` (setado
	// uma vez) e conecta ao chegar o token. Sem a dança de chave-de-tópicos da agenda.
	$effect(() => {
		const cfg = realtime;
		if (!cfg) return;

		const c = connectWaitlist(
			cfg,
			{
				onChange: recarregar,
				onOfferingChange: (porEntrada) => (oferecendo = porEntrada)
			},
			{ userId: data.me?.user?.id ?? null }
		);

		conexao = c;

		return () => {
			conexao = null;
			c.close();
		};
	});

	// Anuncia enquanto o modal estiver aberto. O `return` do efeito cobre o fechar, o trocar de
	// item e o sair da tela — e se a aba morrer, o servidor limpa sozinho (é o ponto da presença).
	$effect(() => {
		const c = conexao;
		const alvo = offering;
		if (!c || !alvo) return;

		c.offering(alvo.id);
		return () => c.stoppedOffering(alvo.id);
	});

	// Remover é destrutivo e sem modal-com-mensagem próprio, então submete a `?/remover`
	// programaticamente (molde do arraste da agenda: fetch + deserialize + toast), fora do
	// caminho do `form` das outras actions.
	async function confirmRemove() {
		if (!removing) return;
		removingBusy = true;
		const body = new FormData();
		body.set('id', removing.id);
		const res = await fetch('?/remover', { method: 'POST', body });
		const result = deserialize(await res.text()) as ActionResult;
		removingBusy = false;
		removing = null;

		if (result.type === 'success') {
			toast('Removido da fila');
			await invalidateAll();
		} else if (result.type === 'failure') {
			toast(String(result.data?.error ?? 'Não foi possível remover.'), 'error');
		}
	}

	// Resultado das actions com modal (enqueue/atualizar/converter). O erro NÃO fecha o modal: a
	// saída ("marcar como encaixe") e o que a pessoa preencheu moram lá dentro. No sucesso, uma
	// mensagem por ação — o load já reexecutou (default do form action), refrescando a lista.
	const SUCESSO: Record<string, string> = {
		enqueue: 'Adicionado à fila',
		atualizar: 'Item atualizado',
		converter: 'Agendamento criado'
	};

	let ultimoForm = $state<unknown>(null);
	$effect(() => {
		if (!form || form === ultimoForm) return;
		ultimoForm = form;
		const action = form.action as string;

		if (form.ok) {
			if (action === 'enqueue') navigate({ novo: null });
			if (action === 'atualizar') editing = null;
			if (action === 'converter') offering = null;
			toast(SUCESSO[action] ?? 'Feito');
		}
		// Erros de enqueue/atualizar/converter ficam DENTRO dos modais (ConflictErrorBox).
	});

	const COLS =
		'md:grid-cols-[minmax(160px,1.7fr)_100px_minmax(200px,2fr)_minmax(90px,0.9fr)_64px_148px]';
	// `max-w-full` + `truncate`: o chip nunca é maior que a coluna — o texto vira reticências e o
	// inteiro fica no `title`. Sem isso ele empurra e cobre a coluna vizinha (doc 38 §5C).
	const chip =
		'max-w-full truncate rounded-[5px] border border-edge-strong px-[7px] py-0.5 text-[10.5px] leading-[1.5] text-ink';
	// Chip de vaga casada (protótipo :2605): mesmo formato do chip, mas clicável e teal — sólido
	// quando a vaga ABRIU (cancelamento/falta), suave quando é uma brecha geral.
	const matchChip =
		'inline-flex max-w-full min-w-0 items-center gap-x-[5px] gap-y-1 rounded-[5px] border px-[7px] py-0.5 text-[10.5px] font-semibold leading-[1.5]';
	const iconBtn =
		'grid size-8 place-items-center rounded-md border border-edge bg-surface text-muted hover:bg-surface-2';
</script>

<svelte:head><title>Fila de espera · Cinetra</title></svelte:head>

<!-- doc 39: "a Fulana já está ligando para este paciente". É aviso, não trava — a linha segue
     inteira clicável, e o portão continua sendo a constraint do agendamento no Confirmar. -->
{#snippet oferecendoAviso(entry: Entry)}
	{@const nomes = oferecendo[entry.id] ?? []}
	{#if nomes.length}
		<span
			title="{nomes.join(', ')} — está com o modal de oferecer aberto agora"
			class="inline-flex max-w-full min-w-0 items-center gap-1 rounded-full bg-surface-2 px-2 py-px text-[10.5px] font-semibold text-muted"
		>
			<Radio size={10} class="shrink-0 text-teal" />
			<span class="truncate">
				{stripTitle(nomes[0])}{nomes.length > 1 ? ` +${nomes.length - 1}` : ''} oferecendo
			</span>
		</span>
	{/if}
{/snippet}

{#snippet dispCell(entry: Entry)}
	<!-- `min-w-0`: item de grid tem `min-width: auto`, ou seja, NÃO encolhe abaixo do conteúdo —
	     e o chip tem texto `nowrap` dentro. Sem isto a célula estoura a coluna e pinta por cima
	     de "Profissional" (achado do bate-volta, doc 38 §5C). Com isto o chip trunca. -->
	<div class="flex min-w-0 flex-wrap items-center gap-1">
		{#each dispItems(entry, slotsFor(entry), data.today) as item, i (i)}
			{#if item.kind === 'neutral'}
				<span
					title={item.label}
					class="{chip} {item.mono ? 'font-mono' : ''} {item.expired
						? 'border-dashed text-faint line-through'
						: ''}">{item.label}</span
				>
			{:else if item.kind === 'match'}
				<button
					type="button"
					onclick={() => openOffer(entry, item.slot)}
					title="Oferecer {slotDateLabel(item.slot)} às {m2t(item.slot.start)}{item.slot.freed
						? ' · vaga que abriu'
						: ''}"
					class="{matchChip} {item.slot.freed
						? 'border-teal bg-teal text-white'
						: 'border-teal-border bg-teal-subtle text-teal-text'}"
				>
					<span
						class="size-1.5 shrink-0 rounded-full {item.slot.freed ? 'bg-white' : 'bg-teal'}"
					></span>
					<!-- O que encolhe é o RÓTULO da regra ("Seg/Ter/Qua…"); a data e a hora ficam
					     inteiras, porque são a informação que faz a pessoa clicar. -->
					<span class="min-w-0 truncate">{item.label}</span>
					<span class="shrink-0 font-mono font-bold whitespace-nowrap">
						{slotDateLabel(item.slot)} {m2t(item.slot.start)}
					</span>
					{#if item.slot.freed}
						<span class="rounded-[3px] bg-white/25 px-1 py-px text-[8.5px] font-extrabold tracking-[.05em]">
							ABRIU
						</span>
					{/if}
				</button>
			{:else}
				<span class="text-[10.5px] text-faint italic">· sem vaga compatível</span>
			{/if}
		{/each}
	</div>
{/snippet}

{#snippet oferecerBtn(entry: Entry)}
	{@const slots = slotsFor(entry)}
	{@const has = slots.length > 0}
	<button
		type="button"
		onclick={() => openOffer(entry)}
		title={has
			? `Próxima vaga: ${slotDateLabel(slots[0])} ${m2t(slots[0].start)}`
			: 'Sem vaga compatível — oferecer manualmente'}
		class="inline-flex flex-1 items-center justify-center gap-1.5 rounded-lg border px-3 py-1.5 text-[12.5px] font-semibold hover:opacity-90 {has
			? 'border-teal-border bg-teal-subtle text-teal-text'
			: 'border-edge-strong bg-transparent text-muted'}"
	>
		{#if has}<span class="size-1.5 shrink-0 rounded-full bg-teal"></span>{/if}
		Oferecer vaga
	</button>
{/snippet}

<div class="px-4 py-4 md:px-4.5">
	<!-- Toolbar mobile: o "+" (o "Adicionar à fila" cheio mora na sidebar, como em Pacientes). -->
	{#if canManage}
		<div class="mb-3.5 flex md:hidden">
			<div class="flex-1"></div>
			<a
				href="/fila?novo=1"
				title="Adicionar à fila"
				aria-label="Adicionar à fila"
				class="grid size-9 shrink-0 place-items-center rounded-lg bg-ink text-canvas hover:opacity-90"
			>
				<Plus size={17} />
			</a>
		</div>
	{/if}

	<div class="overflow-hidden rounded-[12px] border border-edge bg-surface">
		<!-- Cabeçalho (desktop) -->
		<div
			class="hidden gap-4 border-b border-edge px-4 pb-2.5 pt-3 text-[12px] font-medium text-faint md:grid {COLS}"
		>
			<span>Paciente</span><span>Prioridade</span><span>Disponibilidade</span>
			<span>Profissional</span><span class="text-right">Espera</span><span></span>
		</div>

		{#each list as entry (entry.id)}
			{@const rowSlots = slotsFor(entry)}
			{@const rowHasVaga = rowSlots.length > 0}
			<!-- Desktop: linha em grid. Barra teal à esquerda quando há vaga (protótipo :2878). -->
			<div
				class="hidden items-center gap-4 border-b border-edge px-4 py-2.5 last:border-b-0 md:grid {COLS} {rowHasVaga
					? 'shadow-[inset_3px_0_0_var(--mv-teal-solid)]'
					: ''}"
			>
				<span class="flex min-w-0 items-center gap-2.5">
					<span
						class="grid size-7 shrink-0 place-items-center rounded-full text-[10px] font-bold text-white"
						style="background:{entryColor(entry)}"
					>
						{initials(entry.patient.nome)}
					</span>
					<span class="min-w-0">
						<span class="block truncate text-[13px] font-semibold">{entry.patient.nome}</span>
						{#if oferecendo[entry.id]?.length}
							{@render oferecendoAviso(entry)}
						{:else if entry.obs}
							<span class="block truncate text-[11px] text-faint">{entry.obs}</span>
						{/if}
					</span>
				</span>

				<span><PriorityBadge prio={entry.prio} /></span>

				{@render dispCell(entry)}

				<span class="min-w-0 truncate text-[12px] text-muted">{profNames(entry)}</span>

				<span class="text-right">
					<span
						class="font-mono text-[14px] font-semibold tabular-nums {entry.dias_na_fila >= 7
							? 'text-warning'
							: 'text-ink'}">{entry.dias_na_fila}</span
					>
					<span class="block text-[10px] tracking-[.03em] text-faint">
						dia{entry.dias_na_fila === 1 ? '' : 's'}
					</span>
				</span>

				<span class="flex items-center justify-end gap-1.5">
					{#if canManage}
						<button
							type="button"
							onclick={() => openOffer(entry)}
							title={rowHasVaga
								? `Próxima vaga: ${slotDateLabel(rowSlots[0])} ${m2t(rowSlots[0].start)}`
								: 'Sem vaga compatível — oferecer manualmente'}
							class="inline-flex items-center gap-1.5 rounded-lg border px-2.5 py-1.5 text-[12px] font-semibold hover:opacity-90 {rowHasVaga
								? 'border-teal-border bg-teal-subtle text-teal-text'
								: 'border-edge-strong bg-transparent text-muted'}"
						>
							{#if rowHasVaga}<span class="size-1.5 shrink-0 rounded-full bg-teal"></span>{/if}
							Oferecer
						</button>
						<button
							type="button"
							title="Editar"
							aria-label="Editar item de {entry.patient.nome}"
							onclick={() => (editing = entry)}
							class={iconBtn}><Pencil size={14} /></button
						>
						<button
							type="button"
							title="Excluir da fila"
							aria-label="Remover {entry.patient.nome} da fila"
							onclick={() => (removing = entry)}
							class="{iconBtn} text-danger"><Trash2 size={14} /></button
						>
					{/if}
				</span>
			</div>

			<!-- Mobile: cartão. Mesma barra teal do "tem vaga". -->
			<div
				class="flex flex-col gap-2 border-b border-edge px-4 py-3 last:border-b-0 md:hidden {rowHasVaga
					? 'shadow-[inset_3px_0_0_var(--mv-teal-solid)]'
					: ''}"
			>
				<div class="flex items-center gap-2.5">
					<span
						class="grid size-8.5 shrink-0 place-items-center rounded-full text-[11px] font-bold text-white"
						style="background:{entryColor(entry)}"
					>
						{initials(entry.patient.nome)}
					</span>
					<div class="min-w-0 flex-1">
						<div class="truncate text-[14px] font-semibold">{entry.patient.nome}</div>
						<div class="text-[11px] text-faint">
							<span class="font-mono font-semibold {entry.dias_na_fila >= 7 ? 'text-warning' : 'text-muted'}"
								>{entry.dias_na_fila}</span
							>
							dia{entry.dias_na_fila === 1 ? '' : 's'} na fila
						</div>
					</div>
					<PriorityBadge prio={entry.prio} />
				</div>

				{#if entry.obs}<div class="text-[12px] text-muted">{entry.obs}</div>{/if}

				{@render dispCell(entry)}

				<div class="flex items-center gap-1.5 text-[12px] text-muted">
					<Stethoscope size={13} class="shrink-0" />
					<span class="min-w-0 truncate">{profNames(entry)}</span>
				</div>

				{#if canManage}
					<div class="mt-1 flex gap-2">
						{@render oferecerBtn(entry)}
						<button
							type="button"
							aria-label="Editar item de {entry.patient.nome}"
							onclick={() => (editing = entry)}
							class="grid size-9 place-items-center rounded-lg border border-edge bg-surface text-muted"
							><Pencil size={15} /></button
						>
						<button
							type="button"
							aria-label="Remover {entry.patient.nome} da fila"
							onclick={() => (removing = entry)}
							class="grid size-9 place-items-center rounded-lg border border-edge bg-surface text-danger"
							><Trash2 size={15} /></button
						>
					</div>
				{/if}
			</div>
		{/each}

		{#if !list.length}
			<div class="px-7 py-7 text-center text-[13px] text-faint">
				{#if data.prio !== 'todas'}
					Nenhum paciente na fila com esta prioridade.
				{:else}
					Nenhum paciente na fila ainda.
				{/if}
			</div>
		{/if}
	</div>

	<!-- Rodapé de paginação (F6): mesmo desenho e mesmos helpers da lista de Pacientes. Só
	     aparece quando há mais de uma página — a fila curta continua parecendo o que era. -->
	{#if data.pageInfo.more || data.current > 1}
		<div class="mt-3 flex items-center gap-3 px-1">
			<span class="font-mono text-[11.5px] text-faint">
				{pageLabel(data.pageInfo, list.length)}
			</span>
			<div class="flex-1"></div>
			<button
				type="button"
				class={navBtn}
				disabled={data.current === 1}
				onclick={() => goPage(data.current - 1)}
			>
				<ChevronLeft size={14} /> Anterior
			</button>
			<button
				type="button"
				class={navBtn}
				disabled={!data.pageInfo.more}
				onclick={() => goPage(data.current + 1)}
			>
				Próxima <ChevronRight size={14} />
			</button>
		</div>
	{/if}
</div>

{#if showAdd}
	<AddToWaitlistModal
		professionals={data.professionals}
		{search}
		{form}
		onClose={() => navigate({ novo: null })}
	/>
{/if}

{#if editing}
	<AddToWaitlistModal
		entry={editing}
		professionals={data.professionals}
		{search}
		{form}
		onClose={() => (editing = null)}
	/>
{/if}

{#if offering}
	<OfferSlotModal
		entry={offering}
		preselect={preselecting}
		professionals={data.professionals}
		appointmentTypes={data.appointmentTypes}
		timezone={data.timezone}
		papel={data.me?.papel ?? null}
		{form}
		onClose={closeOffer}
	/>
{/if}

{#if removing}
	<ConfirmDialog
		title="Remover da fila"
		confirmLabel="Remover"
		submitting={removingBusy}
		onConfirm={confirmRemove}
		onClose={() => (removing = null)}
	>
		Remover <strong>{removing.patient.nome}</strong> da fila de espera? O item e sua disponibilidade
		serão apagados.
	</ConfirmDialog>
{/if}
