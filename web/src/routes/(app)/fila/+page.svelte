<script lang="ts">
	// Fila de espera (doc 25, Entrega 5). Lista de pacientes aguardando encaixe, ordenada por
	// prioridade; o `?prio=` da sidebar filtra no cliente (a fila é bounded, não paginada). Três
	// modais: adicionar/editar (AddToWaitlistModal), oferecer vaga (OfferSlotModal) e a confirmação
	// de remover (ConfirmDialog). O "Adicionar à fila" mora na sidebar e viaja por `?novo=1` —
	// o único gatilho que precisa cruzar de um componente (a sidebar) para a página.
	import { goto, invalidate, invalidateAll } from '$app/navigation';
	import { deserialize } from '$app/forms';
	import { page as pageState } from '$app/state';
	import { connectWaitlist, type RealtimeConfig } from '$lib/realtime';
	import Plus from '@lucide/svelte/icons/plus';
	import Pencil from '@lucide/svelte/icons/pencil';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import Clock4 from '@lucide/svelte/icons/clock-4';
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
		ruleLabel,
		sortByPriority,
		TIME_WINDOW_LABEL,
		type Entry
	} from '$lib/waitlist';
	import type { SearchResult } from '$lib/agenda';
	import type { ActionResult } from '@sveltejs/kit';
	import type { PageData } from './$types';

	let { data, form }: { data: PageData; form: Record<string, unknown> | null } = $props();

	// Todo membro administra a fila (A8) — inclusive profissional; a autoridade real é a policy.
	const canManage = $derived(canManageWaitlist(data.me?.papel));

	// Filtra por `?prio=` (o segmento da sidebar) e reordena por prioridade. O filtro é do cliente:
	// o GET devolve a fila inteira, e ela é curta (aguardando vaga), como o `renderFila` do protótipo.
	const list = $derived(
		sortByPriority(data.prio === 'todas' ? data.waitlist : data.waitlist.filter((e) => e.prio === data.prio))
	);

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
	let removing = $state<Entry | null>(null);
	let removingBusy = $state(false);

	// Aplica um patch na query string e navega (molde de `pacientes/+page.svelte`). Usado para
	// fechar o modal de adicionar (limpar `?novo`), sem empilhar histórico.
	function navigate(patch: Record<string, string | null>) {
		const params = new URLSearchParams(pageState.url.searchParams);
		for (const [key, value] of Object.entries(patch)) {
			if (value === null || value === '') params.delete(key);
			else params.set(key, value);
		}
		const qs = params.toString();
		goto(qs ? `/fila?${qs}` : '/fila', { keepFocus: true, noScroll: true, replaceState: true });
	}

	async function search(q: string): Promise<SearchResult> {
		const res = await fetch(`/fila/pacientes?q=${encodeURIComponent(q)}`);
		if (!res.ok) return { patients: [], total: 0 };
		return (await res.json()) as SearchResult;
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

	// A fila tem UM tópico só, que nunca muda — então o efeito depende só de `realtime` (setado
	// uma vez) e conecta ao chegar o token. Sem a dança de chave-de-tópicos da agenda.
	$effect(() => {
		const cfg = realtime;
		if (!cfg) return;
		return connectWaitlist(cfg, { onChange: recarregar });
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
	const chip = 'rounded border border-edge px-[7px] py-px text-[10.5px] leading-[1.5] text-ink';
	const iconBtn =
		'grid size-8 place-items-center rounded-md border border-edge bg-surface text-muted hover:bg-surface-2';
</script>

<svelte:head><title>Fila de espera · Cinetra</title></svelte:head>

{#snippet dispCell(entry: Entry)}
	<div class="flex flex-wrap items-center gap-1">
		{#if entry.janela !== 'qualquer'}
			<span class={chip}>{TIME_WINDOW_LABEL[entry.janela]}</span>
		{/if}
		{#each entry.rules as rule (rule.id ?? ruleLabel(rule))}
			<span class="{chip} font-mono">{ruleLabel(rule)}</span>
		{/each}
		{#if !entry.rules.length && entry.janela === 'qualquer'}
			<span class={chip}>Qualquer horário</span>
		{/if}
	</div>
{/snippet}

{#snippet oferecerBtn(entry: Entry, block: boolean)}
	<button
		type="button"
		onclick={() => (offering = entry)}
		class="inline-flex items-center justify-center gap-1.5 rounded-lg border border-teal-border bg-teal-subtle px-3 py-1.5 text-[12.5px] font-semibold text-teal-text hover:opacity-90 {block
			? 'flex-1'
			: ''}"
	>
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

	{#if list.length}
		<div class="overflow-hidden rounded-[10px] border border-edge bg-surface">
			<!-- Cabeçalho (desktop) -->
			<div
				class="hidden gap-4 border-b border-edge px-4 pb-2.5 pt-3 text-[12px] font-medium text-faint md:grid {COLS}"
			>
				<span>Paciente</span><span>Prioridade</span><span>Disponibilidade</span>
				<span>Profissional</span><span class="text-right">Espera</span><span></span>
			</div>

			{#each list as entry (entry.id)}
				<!-- Desktop: linha em grid -->
				<div
					class="hidden items-center gap-4 border-b border-edge px-4 py-2.5 last:border-b-0 md:grid {COLS}"
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
							{#if entry.obs}<span class="block truncate text-[11px] text-faint">{entry.obs}</span>{/if}
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
								onclick={() => (offering = entry)}
								class="inline-flex items-center gap-1.5 rounded-lg border border-teal-border bg-teal-subtle px-2.5 py-1.5 text-[12px] font-semibold text-teal-text hover:opacity-90"
							>
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

				<!-- Mobile: cartão -->
				<div class="flex flex-col gap-2 border-b border-edge px-4 py-3 last:border-b-0 md:hidden">
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
							{@render oferecerBtn(entry, true)}
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
		</div>
	{:else}
		<div class="rounded-[10px] border-t-2 border-edge-strong px-5 py-14 text-center">
			<Clock4 size={26} class="mx-auto text-faint" />
			<div class="mt-2.5 text-[13.5px] font-semibold text-muted">
				Nenhum paciente na fila{data.prio !== 'todas' ? ' com esta prioridade' : ''}
			</div>
			<div class="mt-0.5 text-[12.5px] text-faint">
				Adicione um paciente que aguarda vaga para encaixe.
			</div>
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
		professionals={data.professionals}
		appointmentTypes={data.appointmentTypes}
		timezone={data.timezone}
		papel={data.me?.papel ?? null}
		{form}
		onClose={() => (offering = null)}
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
