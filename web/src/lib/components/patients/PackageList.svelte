<script lang="ts">
	// A seção "Pacotes" da ficha (Fatia 3, reescrita no doc 69 §7).
	//
	// A regra que organiza o cartão: **o cartão informa, o menu executa**. O cartão anterior fazia o
	// contrário — trazia três botões e nenhuma resposta —, e por isso não dava para saber, olhando,
	// que tipo era, com quem, em que dias, nem quando era a próxima sessão. Agora cada pacote diz:
	//
	//   tipo · duração · início      [chip de estado]  ⋯
	//   🗓 Seg 08:00, Qua 09:00 · Ana Prado
	//   ▓▓▓▓░░░░  3/10  7 restantes
	//   🕐 Próxima: Qui 30/07 · 08:00
	//
	// Fiel ao `pkgBlock`/`pkgContext` do protótipo ([`:461`](../../../../interface/Movimento.dc.html#L461)).
	import { enhance } from '$app/forms';
	import Package from '@lucide/svelte/icons/package';
	import Pause from '@lucide/svelte/icons/pause';
	import Play from '@lucide/svelte/icons/play';
	import Plus from '@lucide/svelte/icons/plus';
	import Archive from '@lucide/svelte/icons/archive';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import CalendarX2 from '@lucide/svelte/icons/calendar-x-2';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import Ellipsis from '@lucide/svelte/icons/ellipsis';
	import Hash from '@lucide/svelte/icons/hash';
	import Minus from '@lucide/svelte/icons/minus';
	import ListChecks from '@lucide/svelte/icons/list-checks';
	import SlidersHorizontal from '@lucide/svelte/icons/sliders-horizontal';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import CircleCheck from '@lucide/svelte/icons/circle-check';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envio, envioPorItem } from '$lib/forms.svelte';
	import { zonedParts, m2t } from '$lib/agenda';
	import {
		activeCount,
		gradeLabel,
		isCurrent,
		nextSessionOf,
		packageCode,
		statusChip
	} from '$lib/packages';
	import type { Package as Pkg } from '$lib/packages';
	import { iconComponent, type AppointmentType } from '$lib/appointment-types';

	// Só o que o cartão usa das próximas do paciente — a ficha passa as `HistorySession` inteiras.
	type Upcoming = { id: string; package_id: string | null; starts_at: string };

	let {
		packages,
		professionals = [],
		appointmentTypes = [],
		upcoming = [],
		timezone = 'America/Sao_Paulo',
		canManage = false,
		onNew = undefined,
		onGrade = undefined,
		onSessions = undefined
	}: {
		packages: Pkg[];
		/** resolve o nome do profissional da grade */
		professionals?: { id: string; nome: string }[];
		/** ativos E arquivados: um pacote pode apontar para um tipo já arquivado */
		appointmentTypes?: AppointmentType[];
		/** próximas sessões do paciente (a ficha já as carrega) — daqui sai a "próxima" do pacote */
		upcoming?: Upcoming[];
		timezone?: string;
		/** owner·admin·recepcao·profissional podem mexer; a policy da API é a autoridade */
		canManage?: boolean;
		/** abre o modal de criação (o pai é dono dele) */
		onNew?: () => void;
		/** abre o ajuste de GRADE (dias/horários/profissional das próximas) */
		onGrade?: (pkg: Pkg) => void;
		/** abre a trilha (as sessões da série, com o estado de cada uma) */
		onSessions?: (pkg: Pkg) => void;
	} = $props();

	// Pausar/retomar/arquivar são um form por pacote (em voo POR ITEM); cancelar é um form escondido
	// só, submetido pelo `requestSubmit()` do ConfirmDialog — mesmo padrão do "remover acesso".
	const pausa = envioPorItem<string>();
	const arquivo = envioPorItem<string>();
	const sessao = envioPorItem<string>();
	// O diálogo fica girando até o servidor responder (fechá-lo antes some com a confirmação e nada
	// diz que a operação está indo).
	const cancelamento = envio({
		aoResponder: () => {
			cancelling = null;
		}
	});

	let cancelling = $state<Pkg | null>(null);
	let cancelForm = $state<HTMLFormElement | null>(null);
	let menuAberto = $state<string | null>(null);
	let histAberto = $state(false);

	const atuais = $derived(packages.filter((p) => isCurrent(p.status)));
	const historico = $derived(packages.filter((p) => !isCurrent(p.status)));
	const ativos = $derived(activeCount(packages));

	// A borda da seção acende quando algum pacote pede conversa — acabando ou já completo sem
	// arquivar. É o aviso que a ficha dá de longe, antes de alguém ler o cartão (protótipo :458).
	const precisaAtencao = $derived(
		atuais.some((p) => p.status === 'ativo' && (p.acabando || (p.restantes ?? p.total) === 0))
	);

	function tipoDe(pkg: Pkg): AppointmentType | undefined {
		return appointmentTypes.find((t) => t.id === pkg.appointment_type_id);
	}

	// O rótulo do pacote é o TIPO (nome, duração e cor vêm do catálogo). O `nome` digitado só entra
	// quando o tipo não está à mão — tipo arquivado que o catálogo não trouxe, ou payload antigo.
	function tituloDe(pkg: Pkg): string {
		return tipoDe(pkg)?.nome ?? pkg.nome;
	}

	function corDe(pkg: Pkg): string {
		return tipoDe(pkg)?.cor ?? pkg.cor;
	}

	// "20/07" — a data de início do pacote, curta.
	function diaMes(iso: string): string {
		const [, mes, dia] = iso.split('-');
		return `${dia}/${mes}`;
	}

	// "Qui 30/07/26 · 08:00" no fuso da clínica (mesma conversão de `PatientUpcoming`).
	const DOW_CURTO = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
	function quando(iso: string): string {
		const { date, minutes } = zonedParts(iso, timezone);
		const [ano, mes, dia] = date.split('-');
		const dow = DOW_CURTO[new Date(`${date}T12:00:00Z`).getUTCDay()];
		return `${dow} ${dia}/${mes}/${ano.slice(2)} · ${m2t(minutes)}`;
	}

	// Tom do chip por estado (o `statusChip` decide o rótulo e o ícone; aqui só a pintura).
	const CHIP: Record<string, string> = {
		teal: 'bg-teal-subtle text-teal-text',
		warning: 'bg-warning/14 text-[#9a6a05]',
		faint: 'bg-surface2 text-faint',
		danger: 'bg-danger/10 text-danger'
	};

	// A bolinha da trilha, no desenho do protótipo (`pkgDot`, :394): cheia = consumida; halo = a
	// próxima; contorno = por vir; tracejada = segurada por uma pausa; × branco em vermelho =
	// falta. A cor é a do TIPO — a mesma do bloco na agenda.
	//
	// O halo é `box-shadow` **inline**, e não o `ring-*` do Tailwind: o utilitário monta a sombra a
	// partir de variáveis (`--tw-ring-shadow`) que uma cor inline não alimenta, e o `ring-offset`
	// ainda somava um anel branco por fora — a bolinha "próxima" saía maior que as vizinhas e
	// desalinhava a fila inteira. Sombra não ocupa espaço no layout: todas continuam com 14px.
	const ESTADO: Record<
		string,
		{ label: string; classe: string; estilo: (cor: string) => string }
	> = {
		concluida: {
			label: 'Concluída',
			classe: 'border-transparent',
			estilo: (cor) => `background:${cor}`
		},
		proxima: {
			label: 'Próxima',
			classe: 'border-transparent',
			estilo: (cor) =>
				`background:${cor}; box-shadow:0 0 0 3px color-mix(in srgb, ${cor} 25%, transparent)`
		},
		agendada: {
			label: 'Agendada',
			classe: '',
			estilo: (cor) => `border-color:color-mix(in srgb, ${cor} 45%, transparent)`
		},
		segurada: {
			label: 'Segurada',
			classe: 'border-dashed opacity-60',
			estilo: (cor) => `border-color:color-mix(in srgb, ${cor} 55%, transparent)`
		},
		falta: {
			label: 'Falta',
			classe: 'border-transparent',
			estilo: () => 'background:var(--color-danger)'
		}
	};

	// Arquivar é a porta manual para `concluido` (D1). A tela só a oferece quando não há mais
	// sessão a consumir — o servidor recusa de todo jeito se sobrou sessão futura de pé.
	function podeArquivar(pkg: Pkg): boolean {
		return isCurrent(pkg.status) && (pkg.restantes ?? pkg.total) === 0;
	}
</script>

<!--
	O cabeçalho é o `cardHead` do protótipo ([`:2735`]) — quadrado teal 30×30, título 14px bold —,
	o MESMO dos cinco cartões cadastrais da ficha. Era um ícone cinza solto com título 13px
	maiúsculo: não divergia só do protótipo, divergia dos cartões vizinhos, a 300px de distância
	(doc 51 §L5).
-->
<!-- A âncora existe para o drawer da agenda: ele diz "faltam 2 sessões" e o próximo passo
     (renovar, pausar, ajustar a grade) mora aqui. Sem ela o link cairia no topo da ficha e
     quem clicou teria de procurar a seção. -->
<section
	id="pacotes"
	class="scroll-mt-4 rounded-[14px] border bg-surface p-5 {precisaAtencao
		? 'border-warning/50'
		: 'border-edge'}"
>
	<div class="mb-4 flex items-center gap-2.5">
		<span class="grid size-[30px] shrink-0 place-items-center rounded-lg bg-teal-subtle text-teal-text">
			<Package size={15} />
		</span>
		<h2 class="flex-1 text-[14px] font-bold">
			<!-- o espaço é do CSS (`ml-1`), não um caractere: o Svelte come o whitespace na fronteira
			     do `{#if}` e o rótulo saía colado ("Pacotes· 2 ativos") -->
			Pacotes{#if ativos > 1}<span class="ml-1 font-semibold text-faint">· {ativos} ativos</span
				>{/if}
		</h2>
		{#if canManage}
			<button
				type="button"
				onclick={() => onNew?.()}
				class="inline-flex items-center gap-1.5 rounded-[8px] bg-primary px-2.75 py-1.5 text-[12.5px] font-semibold text-on-primary"
			>
				<Plus size={15} /> Novo pacote
			</button>
		{/if}
	</div>

	{#if packages.length === 0}
		<div class="py-8 text-center text-[13px] text-faint">Nenhum pacote ainda.</div>
	{:else if atuais.length === 0}
		<div class="py-6 text-center">
			<div class="text-[13px] font-semibold text-muted">Sem pacote ativo</div>
			<div class="mt-0.5 text-[12px] text-faint">Os anteriores estão no histórico abaixo.</div>
		</div>
	{/if}

	{#snippet cartao(pkg: Pkg, readonly: boolean)}
		{@const chip = statusChip(pkg)}
		{@const tipo = tipoDe(pkg)}
		{@const proxima = nextSessionOf(upcoming, pkg.id)}
		{@const restantes = pkg.restantes ?? pkg.total}
		<div class="relative pt-3.5 first:pt-0 [&:not(:first-child)]:border-t [&:not(:first-child)]:border-edge">
			<!-- identidade: quadradinho da cor, código, ícone+nome do tipo, duração, início -->
			<div class="mb-2.5 flex items-center gap-2">
				<span
					class="inline-block size-2.5 shrink-0 rounded-[3px]"
					style="background:{corDe(pkg)}"
				></span>
				<div class="flex min-w-0 flex-1 flex-wrap items-center gap-x-2 gap-y-1">
					<!-- o código curto é a identidade falada ("o PIL-2607 da Maria") -->
					<span
						class="shrink-0 rounded-[6px] px-2 py-0.5 font-mono text-[11px] font-bold tracking-[.02em]"
						style="background:color-mix(in srgb, {corDe(pkg)} 13%, transparent); color:{corDe(pkg)}"
					>
						{packageCode(pkg, tipo)}
					</span>
					<span class="inline-flex min-w-0 items-center gap-1.5">
						{#if tipo}
							{@const Icone = iconComponent(tipo.icon)}
							<Icone size={14} style="color:{corDe(pkg)}" />
						{/if}
						<span class="truncate text-[13.5px] font-bold">{tituloDe(pkg)}</span>
					</span>
					<span class="text-[11.5px] text-faint">
						{#if tipo}· {tipo.duracao_minutos}min{/if}
						· início {diaMes(pkg.data_inicio)}
					</span>
				</div>
				<span
					class="inline-flex shrink-0 items-center gap-1 rounded-full px-2.5 py-0.5 text-[11px] font-bold {CHIP[chip.tone]}"
				>
					{#if chip.icone === 'alerta'}<TriangleAlert size={11} />
					{:else if chip.icone === 'pausa'}<Pause size={11} />
					{:else if chip.icone === 'check'}<CircleCheck size={11} />
					{:else if chip.icone === 'x'}<CalendarX2 size={11} />{/if}
					{chip.label}
				</span>
				{#if canManage && !readonly}
					<button
						type="button"
						aria-label="Gerir pacote"
						aria-haspopup="menu"
						aria-expanded={menuAberto === pkg.id}
						onclick={() => (menuAberto = menuAberto === pkg.id ? null : pkg.id)}
						class="-mt-0.5 grid size-7 shrink-0 place-items-center rounded-[7px] border text-muted hover:bg-surface {menuAberto ===
						pkg.id
							? 'border-edge bg-surface'
							: 'border-transparent'}"
					>
						<Ellipsis size={16} />
					</button>
				{/if}
			</div>

			<!-- a grade: que dias, que horas, com quem -->
			{#if pkg.grade}
				<div class="mb-2.5 flex items-center gap-1.5 text-[12px] text-muted">
					<CalendarClock size={13} class="shrink-0 text-faint" />
					<span class="truncate">{gradeLabel(pkg.grade, professionals)}</span>
				</div>
			{/if}

			<!-- A TRILHA: uma bolinha por sessão, na ordem. É o que o contador não diz — QUAIS já
			     foram, qual faltou, qual está segurada, qual é a próxima. Substituiu a barra de
			     progresso, que dizia a mesma coisa que o `3/10` ao lado e nada além. -->
			{#if pkg.sessoes?.length}
				<!-- `gap-x-2` dá ar ao halo da "próxima" (é sombra, não ocupa caixa) -->
				<div class="mb-3 flex flex-wrap gap-x-2 gap-y-1.5" role="list" aria-label="Sessões do pacote">
					{#each pkg.sessoes as s (s.attendance_id)}
						{@const e = ESTADO[s.estado] ?? ESTADO.agendada}
						<span
							role="listitem"
							title="{quando(s.starts_at)} · {e.label}"
							class="box-border grid size-3.5 shrink-0 place-items-center rounded-full border-2 {e.classe}"
							style={e.estilo(corDe(pkg))}
						>
							{#if s.estado === 'falta'}
								<span class="text-[10px] font-bold leading-none text-white">×</span>
							{/if}
						</span>
					{/each}
				</div>
			{/if}

			<!-- o contador: usadas/total grande, restantes ao lado (dois números com papel fixo) -->
			<div class="flex items-baseline gap-2">
				<span class="font-mono text-[19px] font-bold leading-none">
					{pkg.usadas ?? 0}<span class="text-[13px] text-faint">/{pkg.total}</span>
				</span>
				<span
					class="text-[12px] {chip.tone === 'warning' && pkg.status === 'ativo'
						? 'font-semibold text-[#9a6a05]'
						: 'text-muted'}"
				>
					{restantes === 0 ? 'pacote completo' : `${restantes} restantes`}
				</span>
			</div>

			<!-- o contexto: o que este pacote pede AGORA. No histórico não há o que pedir. -->
			{#if readonly}
				<!-- pacote encerrado: o contador e a trilha já contam a história -->
			{:else if pkg.status === 'pausado'}
				<div class="mt-3 rounded-[10px] border border-edge bg-surface2 p-3">
					<div class="flex items-start gap-2.5">
						<Pause size={15} class="mt-0.5 shrink-0 text-faint" />
						<div class="min-w-0">
							<div class="text-[12.5px] font-semibold">Pausado</div>
							<p class="mt-0.5 text-[11.5px] text-muted">
								Validade estendida enquanto pausado. As {restantes} sessões seguradas estão
								<strong>fora da agenda</strong> e voltam ao retomar.
							</p>
						</div>
					</div>
					{#if canManage && !readonly}
						<form method="POST" action="?/resumePackage" use:enhance={pausa.submit(pkg.id)}>
							<input type="hidden" name="package_id" value={pkg.id} />
							<SubmitButton
								emVoo={pausa.emVoo(pkg.id)}
								size={13}
								class="mt-2 flex w-full items-center justify-center gap-1.5 rounded-[8px] border border-edge bg-surface2 py-1.5 text-[12.5px] font-semibold hover:bg-surface disabled:opacity-60"
							>
								<Play size={14} /> Retomar pacote
							</SubmitButton>
						</form>
					{/if}
				</div>
			{:else if restantes === 0}
				<div class="mt-3 flex items-start gap-2.5 rounded-[10px] bg-warning/12 px-3 py-2.5">
					<CircleCheck size={16} class="mt-0.5 shrink-0 text-warning" />
					<div class="min-w-0">
						<div class="text-[12.5px] font-semibold">Pacote concluído</div>
						<p class="mt-0.5 text-[11.5px] text-muted">
							Todas as sessões foram consumidas. Arquive no menu, ou some sessões.
						</p>
					</div>
				</div>
			{:else if pkg.acabando}
				<div class="mt-3 flex items-start gap-2.5 rounded-[10px] bg-warning/12 px-3 py-2.5">
					<TriangleAlert size={16} class="mt-0.5 shrink-0 text-warning" />
					<div class="min-w-0">
						<div class="text-[12.5px] font-semibold">Pacote acabando</div>
						<p class="mt-0.5 text-[11.5px] text-muted">
							{restantes === 1 ? 'Falta 1 sessão' : `Faltam ${restantes} sessões`} para concluir.
						</p>
					</div>
				</div>
			{:else if proxima}
				<div class="mt-2 flex items-center gap-1.5 text-[12px] text-muted">
					<CalendarClock size={13} class="shrink-0 text-faint" />
					<span>
						Próxima: <strong class="font-semibold text-ink">{quando(proxima.starts_at)}</strong>
					</span>
				</div>
			{:else}
				<div class="mt-2 text-[12px] text-faint">Sem próxima sessão agendada.</div>
			{/if}

			<!-- menu ⋯: o cartão informa, aqui é onde se executa -->
			{#if menuAberto === pkg.id}
				<button
					type="button"
					aria-hidden="true"
					tabindex="-1"
					class="fixed inset-0 z-40 cursor-default"
					onclick={() => (menuAberto = null)}
				></button>
				<div
					class="absolute right-2 top-10 z-50 w-56 overflow-hidden rounded-lg border border-edge bg-surface p-1.5 shadow-pop"
				>
					{#if pkg.status === 'ativo'}
						<form method="POST" action="?/pausePackage" use:enhance={pausa.submit(pkg.id)}>
							<input type="hidden" name="package_id" value={pkg.id} />
							<SubmitButton
								emVoo={pausa.emVoo(pkg.id)}
								size={13}
								class="flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-[12.5px] font-medium text-muted hover:bg-surface-2 hover:text-ink disabled:opacity-60"
							>
								<Pause size={15} class="text-faint" /> Pausar pacote
							</SubmitButton>
						</form>
					{:else}
						<form method="POST" action="?/resumePackage" use:enhance={pausa.submit(pkg.id)}>
							<input type="hidden" name="package_id" value={pkg.id} />
							<SubmitButton
								emVoo={pausa.emVoo(pkg.id)}
								size={13}
								class="flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-[12.5px] font-medium text-muted hover:bg-surface-2 hover:text-ink disabled:opacity-60"
							>
								<Play size={15} class="text-faint" /> Retomar pacote
							</SubmitButton>
						</form>
					{/if}

					<!-- o +/− do ADR-011: não há renovação, o total é editável sobre o mesmo pacote.
					     O `−` não escolhe a sessão — o servidor tira a última FUTURA (D3). -->
					{#if pkg.status === 'ativo'}
						<div class="flex items-center gap-2.5 px-2.5 py-1.5">
							<Hash size={15} class="shrink-0 text-faint" />
							<span class="flex-1 text-[12.5px] font-medium text-muted">Sessões</span>
							<form method="POST" action="?/removePackageSession" use:enhance={sessao.submit(pkg.id)}>
								<input type="hidden" name="package_id" value={pkg.id} />
								<SubmitButton
									emVoo={sessao.emVoo(pkg.id)}
									size={12}
									ariaLabel="Tirar sessão"
									trocaConteudo
									class="grid size-6 place-items-center rounded-[6px] border border-edge hover:bg-surface-2 disabled:opacity-50"
								>
									<Minus size={13} />
								</SubmitButton>
							</form>
							<span class="w-5 text-center font-mono text-[12.5px] font-bold">{pkg.total}</span>
							<form method="POST" action="?/addPackageSession" use:enhance={sessao.submit(pkg.id)}>
								<input type="hidden" name="package_id" value={pkg.id} />
								<SubmitButton
									emVoo={sessao.emVoo(pkg.id)}
									size={12}
									ariaLabel="Somar sessão"
									trocaConteudo
									class="grid size-6 place-items-center rounded-[6px] border border-edge hover:bg-surface-2 disabled:opacity-50"
								>
									<Plus size={13} />
								</SubmitButton>
							</form>
						</div>
					{/if}

					{#if onSessions}
						<button
							type="button"
							onclick={() => {
								menuAberto = null;
								onSessions(pkg);
							}}
							class="flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-[12.5px] font-medium text-muted hover:bg-surface-2 hover:text-ink"
						>
							<ListChecks size={15} class="text-faint" /> Ver sessões
						</button>
					{/if}

					{#if pkg.status === 'ativo' && onGrade}
						<button
							type="button"
							onclick={() => {
								menuAberto = null;
								onGrade(pkg);
							}}
							class="flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-[12.5px] font-medium text-muted hover:bg-surface-2 hover:text-ink"
						>
							<SlidersHorizontal size={15} class="text-faint" /> Ajustar grade
						</button>
					{/if}

					{#if podeArquivar(pkg)}
						<form method="POST" action="?/archivePackage" use:enhance={arquivo.submit(pkg.id)}>
							<input type="hidden" name="package_id" value={pkg.id} />
							<SubmitButton
								emVoo={arquivo.emVoo(pkg.id)}
								size={13}
								class="flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-[12.5px] font-medium text-muted hover:bg-surface-2 hover:text-ink disabled:opacity-60"
							>
								<Archive size={15} class="text-faint" /> Arquivar no histórico
							</SubmitButton>
						</form>
					{/if}

					<div class="my-1 h-px bg-edge"></div>

					<button
						type="button"
						onclick={() => {
							menuAberto = null;
							cancelling = pkg;
						}}
						class="flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-[12.5px] font-medium text-danger hover:bg-danger/8"
					>
						<CalendarX2 size={15} /> Cancelar pacote
					</button>
				</div>
			{/if}
		</div>
	{/snippet}

	{#if atuais.length}
		<div class="flex flex-col">
			{#each atuais as pkg (pkg.id)}
				{@render cartao(pkg, false)}
			{/each}
		</div>
	{/if}

	<!-- histórico: cancelado e concluído saem do caminho, mas continuam alcançáveis -->
	{#if historico.length}
		<div class="mt-3 border-t border-edge pt-1">
			<button
				type="button"
				onclick={() => (histAberto = !histAberto)}
				aria-expanded={histAberto}
				class="flex w-full items-center gap-2 py-2 text-muted"
			>
				<ChevronDown
					size={16}
					class="text-faint transition-transform {histAberto ? '' : '-rotate-90'}"
				/>
				<span class="flex-1 text-left text-[12.5px] font-bold">Histórico</span>
				<span class="font-mono text-[11px] text-faint">{historico.length}</span>
			</button>
			{#if histAberto}
				<div class="flex flex-col pb-1 pt-1">
					{#each historico as pkg (pkg.id)}
						{@render cartao(pkg, true)}
					{/each}
				</div>
			{/if}
		</div>
	{/if}
</section>

<!-- form escondido do cancelamento: o ConfirmDialog só decide se ele é submetido -->
<form
	bind:this={cancelForm}
	method="POST"
	action="?/cancelPackage"
	class="hidden"
	use:enhance={cancelamento.submit}
>
	<input type="hidden" name="package_id" value={cancelling?.id ?? ''} />
</form>

{#if cancelling}
	<ConfirmDialog
		title="Cancelar pacote"
		confirmLabel="Cancelar pacote"
		submitting={cancelamento.emVoo}
		onConfirm={() => cancelForm?.requestSubmit()}
		onClose={() => (cancelling = null)}
	>
		<!-- o número é a consequência: sem ele a confirmação pede um "sim" no escuro -->
		As <strong>{cancelling.restantes ?? cancelling.total} sessões futuras</strong> de
		<strong>{tituloDe(cancelling)}</strong> serão canceladas e liberadas da agenda. As já concluídas
		ou faltadas permanecem no histórico.
	</ConfirmDialog>
{/if}
