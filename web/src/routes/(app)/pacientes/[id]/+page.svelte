<script lang="ts">
	import { enhance } from '$app/forms';
	import SubmitButton from '$lib/components/SubmitButton.svelte';
	import { envio } from '$lib/forms.svelte';
	import { invalidateAll } from '$app/navigation';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import Pencil from '@lucide/svelte/icons/pencil';
	import CreditCard from '@lucide/svelte/icons/credit-card';
	import BellRing from '@lucide/svelte/icons/bell-ring';
	import BellOff from '@lucide/svelte/icons/bell-off';
	import Phone from '@lucide/svelte/icons/phone';
	import User from '@lucide/svelte/icons/user';
	import Siren from '@lucide/svelte/icons/siren';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import Briefcase from '@lucide/svelte/icons/briefcase';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import Archive from '@lucide/svelte/icons/archive';
	import ArchiveRestore from '@lucide/svelte/icons/archive-restore';
	import CalendarPlus from '@lucide/svelte/icons/calendar-plus';
	import { initials } from '$lib/format';
	import { avatarStyle } from '$lib/avatar';
	import { toast } from '$lib/toast.svelte';
	import { patientColor, convLabel, idade, prefNomes, canManagePatients } from '$lib/patients';
	import { canManageAttachments } from '$lib/attachments';
	import PackageList from '$lib/components/patients/PackageList.svelte';

	// Arquivar/reativar recarregam a ficha inteira — sem sinal, o clique parecia perdido.
	const situacao = envio();
	import PackageCreateModal from '$lib/components/patients/PackageCreateModal.svelte';
	import PackageGradeModal from '$lib/components/patients/PackageGradeModal.svelte';
	import PackageSessionsModal from '$lib/components/patients/PackageSessionsModal.svelte';
	import PatientUpcoming from '$lib/components/patients/PatientUpcoming.svelte';
	import PatientHistory from '$lib/components/patients/PatientHistory.svelte';
	import PatientAttachments from '$lib/components/patients/PatientAttachments.svelte';
	import type { Package as Pkg } from '$lib/packages';
	import { formatarTelefone } from '$lib/telefone';
	// O CPF é canônico no banco (só dígitos) desde 2026-07-29; a máscara é da leitura.
	import { maskCpf } from '$lib/masks';
	import type { PageData, ActionData } from './$types';

	let { data, form }: { data: PageData; form: ActionData } = $props();

	// O modal de criação de pacote é dono do pai (a ficha): abre pelo "Novo pacote" da lista e, ao
	// criar, recarrega a ficha (`invalidateAll`) para o novo pacote aparecer com os contadores.
	let criandoPacote = $state(false);

	// A grade (contrato 09:441) e a trilha (doc 69 §7 item 9) são do pai porque a grade submete uma
	// action DESTA página e a trilha depende do catálogo de tipos para dizer o nome do pacote.
	let ajustandoGrade = $state<Pkg | null>(null);
	let vendoSessoes = $state<Pkg | null>(null);

	// A grade fecha no sucesso; o erro mantém o modal aberto, com a mensagem do servidor.
	$effect(() => {
		if (form?.ok) ajustandoGrade = null;
	});

	// Falha de action vira toast — MENOS a da grade, que tem modal aberto e mostra a mensagem lá
	// dentro (repetir seria a mesma frase duas vezes, uma delas por cima do que a pessoa digitou).
	//
	// Este era o buraco: `form.error` só estava ligado ao modal da grade, e ele só existe enquanto
	// está aberto. Arquivar o paciente sem permissão, ou o 422 do arquivar-pacote ("ainda há sessão
	// futura" — que o próprio servidor documenta como "o erro vai para a tela"), paravam o giro do
	// botão e não diziam mais nada.
	$effect(() => {
		if (!form || form.ok || form.action === 'grade') return;
		toast(form.error ?? 'Não foi possível concluir a ação.', 'error');
	});

	// O título do modal da trilha é o do TIPO — a mesma identidade que o cartão usa.
	const tituloDoPacote = $derived((pkg: Pkg) =>
		data.appointmentTypes.find((t) => t.id === pkg.appointment_type_id)?.nome ?? pkg.nome
	);

	const p = $derived(data.patient);
	const canManage = $derived(canManagePatients(data.me.papel));
	// Anexos têm recorte PRÓPRIO de papel (owner·admin·recepção, doc 51): o `profissional` não vê
	// a seção. É a única parte da ficha que não segue o "todo membro visualiza" do D16.
	const canAttach = $derived(canManageAttachments(data.me.papel));
	const nomePorId = $derived(
		Object.fromEntries(data.professionals.map((x) => [x.id, x.nome])) as Record<string, string>
	);
	const prefs = $derived(prefNomes(p, nomePorId));
	const idadeVal = $derived(idade(p.nascimento));
	const endereco = $derived(
		[p.endereco, p.numero && `nº ${p.numero}`, p.complemento].filter(Boolean).join(', ')
	);
	const cidadeUf = $derived([p.cidade, p.uf].filter(Boolean).join(' / '));

	// ---- O cadastro, como dado (doc 56) ----
	//
	// Era markup: cinco cartões escritos à mão, cada um com um par de snippets (`contatoBody` +
	// `contatoRows`) e um `kv` por campo, que desenhava um travessão quando o campo era vazio.
	// Medido ao vivo: **20 dos 27 campos** de um paciente de verdade eram `—`, e a página gastava
	// ~1.280px reservando espaço para dado que não existe. A ficha mais vazia possível abria com
	// 1.592px, 2,4 telas.
	//
	// Descrever os cartões como dado é o que permite a decisão passar a ser calculada: esconder o
	// campo vazio, esconder o cartão que ficou sem nenhum campo, e ainda assim saber **quantos**
	// ficaram de fora para o rodapé não deixar o "falta preencher" invisível.
	type Campo = { l: string; v: string | null | undefined; mono?: boolean; wide?: boolean };

	const preenchido = (v: string | null | undefined) =>
		v !== undefined && v !== null && v !== '' && v !== '—';

	// A ORDEM dos cartões é a ordem das perguntas de quem atende ao telefone; `recolhido` marca o
	// que é conferência cadastral, não atendimento (M4). A hipótese original era recolher o
	// cadastro inteiro — a medição do M1 a derrubou: com o campo vazio fora, a coluna caiu de
	// ~1.280px para ~350px num paciente típico, e recolher dado que alguém digitou de propósito
	// passou a custar mais do que rende. Sobraram os dois cartões que ninguém abre com o paciente
	// na linha.
	const cartoes = $derived([
		{
			icon: Phone,
			title: 'Contato',
			campos: [
				{ l: 'Telefone / WhatsApp', v: formatarTelefone(p.tel), mono: true },
				{ l: 'E-mail', v: p.email },
				// "Responsável legal" veio de Identificação: paciente menor de idade é caso de
				// ATENDIMENTO (a lista tem até o segmento "Com responsável"), e atrás de um clique
				// ele deixaria de ser visto na hora em que importa.
				{ l: 'Responsável legal', v: p.responsavel, wide: true },
				{ l: 'Endereço', v: endereco, wide: true },
				{ l: 'Bairro', v: p.bairro },
				{ l: 'Cidade / UF', v: cidadeUf },
				{ l: 'CEP', v: p.cep, mono: true }
			] as Campo[]
		},
		{
			icon: Stethoscope,
			title: 'Atendimento & convênio',
			campos: [
				// "Tipo de atendimento" saiu: era `convLabel(p)` numa célula colada em "Convênio",
				// que num paciente de convênio mostra a MESMA string — e o chip do cabeçalho já a
				// dizia uma terceira vez.
				{ l: 'Convênio', v: p.convenio },
				{ l: 'Carteirinha', v: p.carteirinha, mono: true },
				{ l: 'Validade', v: p.convenio_validade, mono: true },
				{ l: 'Médico solicitante', v: p.medico },
				{ l: 'CRM', v: p.crm, mono: true },
				{ l: 'Profissional preferido', v: prefs.length ? prefs.join(', ') : null }
			] as Campo[]
		},
		{
			icon: Siren,
			title: 'Contato de emergência',
			campos: [
				{ l: 'Nome', v: p.emergencia_nome },
				{ l: 'Parentesco', v: p.emergencia_parentesco },
				{ l: 'Telefone', v: p.emergencia_tel, mono: true, wide: true }
			] as Campo[]
		},
		{
			icon: User,
			title: 'Identificação',
			recolhido: true,
			campos: [
				{ l: 'Nascimento', v: p.nascimento, mono: true },
				// "Idade" saiu daqui: é stat do cabeçalho, e dizer duas vezes na mesma tela o que
				// se deriva de uma data só é ruído (doc 56, M2).
				{ l: 'Gênero', v: p.genero },
				{ l: 'Estado civil', v: p.estado_civil },
				{ l: 'RG', v: p.rg, mono: true }
			] as Campo[]
		},
		{
			icon: Briefcase,
			title: 'Perfil',
			recolhido: true,
			campos: [
				{ l: 'Profissão', v: p.profissao },
				{ l: 'Empresa', v: p.empresa },
				{ l: 'Como conheceu', v: p.como_conheceu }
			] as Campo[]
		}
	]);

	// Cartão sem nenhum campo preenchido não é desenhado. "Contato de emergência" vazio custava
	// 174px para exibir três travessões.
	const cartoesVisiveis = $derived(
		cartoes
			.map((c) => ({ ...c, campos: c.campos.filter((x) => preenchido(x.v)) }))
			.filter((c) => c.campos.length > 0)
	);

	// Esconder o vazio esconde junto o "falta preencher". O rodapé devolve isso em uma linha.
	const naoPreenchidos = $derived(
		cartoes.flatMap((c) => c.campos).filter((x) => !preenchido(x.v)).length
	);
</script>

<svelte:head><title>{p.nome} · Pacientes · Cinetra</title></svelte:head>

{#snippet cabecalho(icon: typeof User, title: string)}
	{@const Icon = icon}
	<span class="grid size-[30px] shrink-0 place-items-center rounded-lg bg-teal-subtle text-teal-text">
		<Icon size={15} />
	</span>
	<div class="text-[14px] font-bold">{title}</div>
{/snippet}

{#snippet campos(lista: Campo[])}
	<div class="grid grid-cols-2 gap-x-[18px] gap-y-3.5">
		{#each lista as c (c.l)}
			<div class="min-w-0 {c.wide ? 'col-span-2' : ''}">
				<div class="mb-0.5 text-[11px] text-faint">{c.l}</div>
				<div class="break-words text-[13.5px] font-medium text-ink {c.mono ? 'font-mono' : ''}">
					{c.v}
				</div>
			</div>
		{/each}
	</div>
{/snippet}

<!--
	Um cartão do cadastro. Recebe os campos já filtrados (só os preenchidos) — a decisão de
	esconder é do `$derived`, não do markup, para o rodapé poder contar o que ficou de fora.

	`recolhido` usa `<details>` nativo, e não um `{#if}` com estado: abre por teclado, o conteúdo
	continua no DOM (o Chrome expande na busca da página) e não há estado para sincronizar entre
	as duas instâncias que o layout renderiza. Custo assumido: `<details>` fechado não é achado
	pelo Ctrl+F de todo navegador — por isso só os dois cartões de conferência entram aqui, nunca
	telefone, convênio ou emergência.
-->
{#snippet card(icon: typeof User, title: string, lista: Campo[], recolhido = false)}
	{#if recolhido}
		<details class="group rounded-[14px] border border-edge bg-surface p-5">
			<summary class="flex cursor-pointer list-none items-center gap-2.5">
				{@render cabecalho(icon, title)}
				<ChevronDown
					size={16}
					class="ml-auto text-faint transition-transform group-open:rotate-180"
				/>
			</summary>
			<div class="mt-4">{@render campos(lista)}</div>
		</details>
	{:else}
		<div class="rounded-[14px] border border-edge bg-surface p-5">
			<div class="mb-4 flex items-center gap-2.5">{@render cabecalho(icon, title)}</div>
			{@render campos(lista)}
		</div>
	{/if}
{/snippet}

<div class="mx-auto max-w-[1180px] px-4 py-4 md:px-[22px] md:py-[18px]">
	<a href="/pacientes" class="mb-3.5 inline-flex items-center gap-1.5 text-[13px] text-muted hover:text-ink">
		<ChevronLeft size={16} /> Pacientes
	</a>

	{#if !p.ativo}
		<div class="mb-4 flex flex-wrap items-center gap-3 rounded-[14px] border border-warning/30 bg-warning/10 px-4 py-3">
			<Archive size={17} class="text-warning" />
			<span class="flex-1 text-[13px] text-ink">
				<b>Paciente arquivado</b> — não aparece na lista de ativos.
			</span>
			{#if canManage}
				<form method="POST" action="?/reactivate" use:enhance={situacao.submit}>
					<SubmitButton
						emVoo={situacao.emVoo}
						size={15}
						class="inline-flex items-center gap-1.5 rounded-lg border border-edge bg-surface px-3.5 py-2 text-[13px] font-semibold text-ink hover:bg-surface-2 disabled:opacity-60"
					>
						<ArchiveRestore size={15} /> Reativar
					</SubmitButton>
				</form>
			{/if}
		</div>
	{/if}

	<!-- Cabeçalho -->
	<div class="mb-4 rounded-2xl border border-edge bg-surface p-5 md:px-6 md:py-[22px]">
		<div class="flex flex-wrap items-start gap-4">
			<span
				class="grid size-[54px] shrink-0 place-items-center rounded-full text-[20px] font-bold md:size-16"
				style={avatarStyle(p.cor_indice)}
			>
				{initials(p.nome)}
			</span>
			<div class="min-w-0 flex-1 basis-60">
				<div class="text-[20px] font-bold leading-tight md:text-[24px]">{p.nome}</div>
				{#if p.nome_social}<div class="mt-0.5 text-[13px] text-muted">“{p.nome_social}”</div>{/if}
				<div class="mt-1.5 flex flex-wrap items-center gap-2.5 text-[12.5px] text-muted">
					<span class="font-mono">{maskCpf(p.cpf ?? '') || 'CPF não informado'}</span>
					<span class="inline-flex items-center gap-1.5 rounded-full bg-teal-subtle px-2.5 py-0.5 text-[11.5px] font-semibold text-teal-text">
						<CreditCard size={12} /> {convLabel(p)}
					</span>
					<!-- O que o cartão "Consentimentos" acrescentava a este selo era a COBERTURA de
					     cada consentimento — texto estático, igual em toda ficha. Virou `title`: o
					     cartão custava 216px para repetir dois booleanos que o topo já dizia. -->
					{#if p.comunicacao}
						<span
							title="WhatsApp, ligação e e-mail — lembretes e campanhas"
							class="inline-flex items-center gap-1.5 text-[11.5px] text-success"><BellRing size={13} /> Contato autorizado</span>
					{:else}
						<span
							title="WhatsApp, ligação e e-mail — lembretes e campanhas"
							class="inline-flex items-center gap-1.5 text-[11.5px] text-faint"><BellOff size={13} /> Sem autorização de contato</span>
					{/if}
				</div>
			</div>
			<div class="flex shrink-0 flex-wrap gap-2.5">
				<!-- "Agendar" é do protótipo ([`:2756`]) e faltava: o caminho só existia ao contrário
				     (o drawer da agenda levava à ficha). Quem atende ao telefone abre a ficha,
				     confirma o convênio e precisa marcar dali, sem buscar o paciente de novo. -->
				{#if p.ativo}
					<a
						href="/agenda?paciente={p.id}"
						class="flex items-center gap-1.5 rounded-[9px] border border-edge bg-surface px-3.5 py-2 text-[13px] font-semibold text-ink hover:bg-surface-2"
					>
						<CalendarPlus size={15} /> Agendar
					</a>
				{/if}
				{#if canManage}
					{#if p.ativo}
						<form method="POST" action="?/deactivate" use:enhance={situacao.submit}>
							<SubmitButton
								emVoo={situacao.emVoo}
								title="Arquivar paciente"
								size={15}
								class="flex items-center gap-1.5 rounded-[9px] border border-edge bg-surface px-3.5 py-2 text-[13px] font-semibold text-muted hover:bg-surface-2 disabled:opacity-60"
							>
								<Archive size={15} /> Arquivar
							</SubmitButton>
						</form>
					{/if}
					<a
						href="/pacientes/{p.id}/editar"
						class="flex items-center gap-1.5 rounded-[9px] bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary hover:bg-primary-hover"
					>
						<Pencil size={14} /> Editar dados
					</a>
				{/if}
			</div>
		</div>

		{#if p.tags.length}
			<div class="mt-3.5 flex flex-wrap gap-1.5">
				{#each p.tags as t (t)}
					<span class="rounded-full border border-edge bg-surface-2 px-2.5 py-0.5 text-[12px] text-muted">{t}</span>
				{/each}
			</div>
		{/if}

		<div class="mt-4 grid grid-cols-2 gap-2.5 md:grid-cols-3">
			{#snippet stat(l: string, v: string, accent: string, hint = '')}
				<div class="rounded-[11px] border border-edge bg-surface-2 px-3.5 py-3" title={hint}>
					<div class="mb-1 text-[10.5px] uppercase tracking-[.04em] text-faint">{l}</div>
					<div class="font-mono text-[16px] font-bold {accent}">{v}</div>
				</div>
			{/snippet}
			{@render stat('Idade', idadeVal !== null ? `${idadeVal} anos` : '—', 'text-ink')}
			<!-- "Faltas" é o stat do protótipo ([`:2763`]). O agregado existe desde a agenda e já
			     alimentava drawer e fila; faltava chegar aqui. Substitui "Comunicação", que dizia
			     pela terceira vez na mesma tela o que o selo do topo e o cartão de consentimentos
			     já diziam. -->
			{@render stat(
				'Faltas',
				p.faltas != null ? String(p.faltas) : '—',
				p.faltas ? 'text-danger' : 'text-ink'
			)}
			{@render stat(
				'Consentimento LGPD',
				p.lgpd ? 'OK' : 'Pendente',
				p.lgpd ? 'text-success' : 'text-faint',
				'Prontuário, documentos e assistência'
			)}
		</div>
	</div>

	<!--
		Duas colunas, como no protótipo ([`:2768`]): à esquerda o CADASTRO (estático, consultado);
		à direita a ATIVIDADE (pacotes, histórico, anexos — o que se olha primeiro).

		Era uma grade `md:grid-cols-2` com os cinco cartões cadastrais, e pacotes/histórico em
		largura cheia embaixo. Isso deixava um buraco na segunda coluna da terceira linha (cinco
		cartões numa grade de dois) e empurrava o histórico para fora da dobra, enquanto "Pacotes"
		usava 1180px para mostrar uma barra de progresso.

		`flex-wrap` com bases 340/300px: em telas estreitas as colunas empilham sozinhas, sem
		breakpoint.
	-->
	<div class="flex flex-wrap items-start gap-4">
	<!--
		A coluna do CADASTRO. Perdeu a proporção maior (era `1.5`) porque, com o campo vazio fora,
		ela deixou de ser a coluna alta: quem cresce é a atividade, que cresce com o paciente.
	-->
	<div class="flex min-w-0 flex-[1_1_320px] flex-col gap-4">
		{#each cartoesVisiveis as c (c.title)}
			{@render card(c.icon, c.title, c.campos, c.recolhido)}
		{/each}

		<!--
			O que M1 tirou da tela em silêncio. Sem esta linha, "falta preencher o convênio" deixa de
			existir como informação: o travessão era feio, mas dizia. Uma linha diz o mesmo.
			Só para quem pode editar — oferecer o caminho a quem leva 403 é pior que não oferecer.
		-->
		{#if naoPreenchidos > 0 && canManage}
			<a
				href="/pacientes/{p.id}/editar"
				class="rounded-[14px] border border-dashed border-edge px-4 py-3 text-[12.5px] text-muted hover:border-primary hover:text-ink"
			>
				{naoPreenchidos}
				{naoPreenchidos === 1 ? 'campo não preenchido' : 'campos não preenchidos'} · Completar
				cadastro
			</a>
		{/if}
	</div>

	<!--
		Coluna da ATIVIDADE: próximas, pacotes, histórico e anexos. "Próximas" abre a coluna porque
		é a pergunta que se faz com o telefone na mão ("quando ele volta?") — e era a única das
		quatro que a ficha não respondia (doc 56).
	-->
	<div class="flex min-w-0 flex-[1.2_1_320px] flex-col gap-4">
		<!-- Próximas sessões (doc 56). -->
		<PatientUpcoming
			sessions={data.upcoming}
			more={data.upcomingMore}
			timezone={data.me.timezone ?? 'America/Sao_Paulo'}
			patientId={p.id}
		/>

		<!-- Pacotes (Fatia 3): lista + ciclo de vida + criação (modal com prévia ao vivo). -->
		<PackageList
			packages={data.packages}
			professionals={data.professionals}
			appointmentTypes={data.appointmentTypes}
			upcoming={data.upcoming}
			timezone={data.me.timezone ?? 'America/Sao_Paulo'}
			{canManage}
			onNew={() => (criandoPacote = true)}
			onGrade={(pkg) => (ajustandoGrade = pkg)}
			onSessions={(pkg) => (vendoSessoes = pkg)}
		/>

		<!-- Histórico (C13, Frente 7). Abre com 8 linhas; o resto é o "ver histórico completo". -->
		<PatientHistory
			sessions={data.history}
			more={data.historyMore}
			timezone={data.me.timezone ?? 'America/Sao_Paulo'}
		/>

		<!-- Anexos (doc 51). Escondido para quem não pode: mostrar a seção e dar 403 no clique
		     seria pior que não mostrá-la — a policy da API continua sendo quem barra. -->
		{#if canAttach}
			<PatientAttachments
				patientId={p.id}
				attachments={data.attachments}
				limites={data.attachmentLimits}
				onChanged={() => invalidateAll()}
			/>
		{/if}
	</div>
	</div>

</div>

{#if criandoPacote}
	<PackageCreateModal
		patientId={p.id}
		professionals={data.professionals}
		appointmentTypes={data.appointmentTypes}
		onClose={() => (criandoPacote = false)}
		onCreated={() => {
			criandoPacote = false;
			invalidateAll();
		}}
	/>
{/if}

{#if ajustandoGrade}
	<PackageGradeModal
		pkg={ajustandoGrade}
		professionals={data.professionals}
		erro={form?.ok ? undefined : form?.error}
		onClose={() => (ajustandoGrade = null)}
	/>
{/if}

{#if vendoSessoes}
	<PackageSessionsModal
		pkg={vendoSessoes}
		patientId={p.id}
		titulo={tituloDoPacote(vendoSessoes)}
		timezone={data.me.timezone ?? 'America/Sao_Paulo'}
		onClose={() => (vendoSessoes = null)}
	/>
{/if}

