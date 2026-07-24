<script lang="ts">
	import { enhance } from '$app/forms';
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
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import Archive from '@lucide/svelte/icons/archive';
	import ArchiveRestore from '@lucide/svelte/icons/archive-restore';
	import { initials } from '$lib/format';
	import { patientColor, convLabel, idade, prefNomes, canManagePatients } from '$lib/patients';
	import PackageList from '$lib/components/patients/PackageList.svelte';
	import PackageCreateModal from '$lib/components/patients/PackageCreateModal.svelte';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	// O modal de criação de pacote é dono do pai (a ficha): abre pelo "Novo pacote" da lista e, ao
	// criar, recarrega a ficha (`invalidateAll`) para o novo pacote aparecer com os contadores.
	let criandoPacote = $state(false);

	const p = $derived(data.patient);
	const canManage = $derived(canManagePatients(data.me.papel));
	const nomePorId = $derived(
		Object.fromEntries(data.professionals.map((x) => [x.id, x.nome])) as Record<string, string>
	);
	const prefs = $derived(prefNomes(p, nomePorId));
	const idadeVal = $derived(idade(p.nascimento));
	const endereco = $derived(
		[p.endereco, p.numero && `nº ${p.numero}`, p.complemento].filter(Boolean).join(', ')
	);
	const cidadeUf = $derived([p.cidade, p.uf].filter(Boolean).join(' / '));
</script>

<svelte:head><title>{p.nome} · Pacientes · Cinetra</title></svelte:head>

{#snippet card(icon: typeof User, title: string, body: import('svelte').Snippet)}
	{@const Icon = icon}
	<div class="rounded-[14px] border border-edge bg-surface p-5">
		<div class="mb-4 flex items-center gap-2.5">
			<span class="grid size-[30px] shrink-0 place-items-center rounded-lg bg-teal-subtle text-teal-text">
				<Icon size={15} />
			</span>
			<div class="text-[14px] font-bold">{title}</div>
		</div>
		{@render body()}
	</div>
{/snippet}

{#snippet kv(l: string, v: string | null | undefined, mono = false)}
	{@const empty = v === undefined || v === null || v === '' || v === '—'}
	<div class="min-w-0">
		<div class="mb-0.5 text-[11px] text-faint">{l}</div>
		<div class="break-words text-[13.5px] font-medium {empty ? 'text-faint' : 'text-ink'} {mono ? 'font-mono' : ''}">
			{empty ? '—' : v}
		</div>
	</div>
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
				<form method="POST" action="?/reactivate" use:enhance>
					<button class="inline-flex items-center gap-1.5 rounded-lg border border-edge bg-surface px-3.5 py-2 text-[13px] font-semibold text-ink hover:bg-surface-2">
						<ArchiveRestore size={15} /> Reativar
					</button>
				</form>
			{/if}
		</div>
	{/if}

	<!-- Cabeçalho -->
	<div class="mb-4 rounded-2xl border border-edge bg-surface p-5 md:px-6 md:py-[22px]">
		<div class="flex flex-wrap items-start gap-4">
			<span
				class="grid size-[54px] shrink-0 place-items-center rounded-full text-[20px] font-bold text-white md:size-16"
				style="background:{patientColor(p.cor_indice)}"
			>
				{initials(p.nome)}
			</span>
			<div class="min-w-0 flex-1 basis-60">
				<div class="text-[20px] font-bold leading-tight md:text-[24px]">{p.nome}</div>
				{#if p.nome_social}<div class="mt-0.5 text-[13px] text-muted">“{p.nome_social}”</div>{/if}
				<div class="mt-1.5 flex flex-wrap items-center gap-2.5 text-[12.5px] text-muted">
					<span class="font-mono">{p.cpf || 'CPF não informado'}</span>
					<span class="inline-flex items-center gap-1.5 rounded-full bg-teal-subtle px-2.5 py-0.5 text-[11.5px] font-semibold text-teal-text">
						<CreditCard size={12} /> {convLabel(p)}
					</span>
					{#if p.comunicacao}
						<span class="inline-flex items-center gap-1.5 text-[11.5px] text-success"><BellRing size={13} /> Contato autorizado</span>
					{:else}
						<span class="inline-flex items-center gap-1.5 text-[11.5px] text-faint"><BellOff size={13} /> Sem autorização de contato</span>
					{/if}
				</div>
			</div>
			{#if canManage}
				<div class="flex shrink-0 gap-2.5">
					{#if p.ativo}
						<form method="POST" action="?/deactivate" use:enhance>
							<button
								title="Arquivar paciente"
								class="flex items-center gap-1.5 rounded-[9px] border border-edge bg-surface px-3.5 py-2 text-[13px] font-semibold text-muted hover:bg-surface-2"
							>
								<Archive size={15} /> Arquivar
							</button>
						</form>
					{/if}
					<a
						href="/pacientes/{p.id}/editar"
						class="flex items-center gap-1.5 rounded-[9px] bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary hover:bg-primary-hover"
					>
						<Pencil size={14} /> Editar dados
					</a>
				</div>
			{/if}
		</div>

		{#if p.tags.length}
			<div class="mt-3.5 flex flex-wrap gap-1.5">
				{#each p.tags as t (t)}
					<span class="rounded-full border border-edge bg-surface-2 px-2.5 py-0.5 text-[12px] text-muted">{t}</span>
				{/each}
			</div>
		{/if}

		<div class="mt-4 grid grid-cols-2 gap-2.5 md:grid-cols-3">
			{#snippet stat(l: string, v: string, accent: string)}
				<div class="rounded-[11px] border border-edge bg-surface-2 px-3.5 py-3">
					<div class="mb-1 text-[10.5px] uppercase tracking-[.04em] text-faint">{l}</div>
					<div class="font-mono text-[16px] font-bold {accent}">{v}</div>
				</div>
			{/snippet}
			{@render stat('Idade', idadeVal !== null ? `${idadeVal} anos` : '—', 'text-ink')}
			{@render stat('Consentimento LGPD', p.lgpd ? 'OK' : 'Pendente', p.lgpd ? 'text-success' : 'text-faint')}
			{@render stat('Comunicação', p.comunicacao ? 'Autorizada' : 'Não', p.comunicacao ? 'text-success' : 'text-faint')}
		</div>
	</div>

	<!-- Cartões cadastrais -->
	<div class="grid grid-cols-1 gap-4 md:grid-cols-2">
		{#snippet grid2(body: import('svelte').Snippet)}
			<div class="grid grid-cols-2 gap-x-[18px] gap-y-3.5">{@render body()}</div>
		{/snippet}

		{#snippet contatoBody()}
			{@render grid2(contatoRows)}
		{/snippet}
		{#snippet contatoRows()}
			{@render kv('Telefone / WhatsApp', p.tel, true)}
			{@render kv('E-mail', p.email)}
			<div class="col-span-2">{@render kv('Endereço', endereco)}</div>
			{@render kv('Bairro', p.bairro)}
			{@render kv('Cidade / UF', cidadeUf)}
			{@render kv('CEP', p.cep, true)}
		{/snippet}
		{@render card(Phone, 'Contato', contatoBody)}

		{#snippet identBody()}
			{@render grid2(identRows)}
		{/snippet}
		{#snippet identRows()}
			{@render kv('Nascimento', p.nascimento, true)}
			{@render kv('Idade', idadeVal !== null ? `${idadeVal} anos` : '—', true)}
			{@render kv('Gênero', p.genero)}
			{@render kv('Estado civil', p.estado_civil)}
			{@render kv('RG', p.rg, true)}
			{@render kv('Responsável legal', p.responsavel)}
		{/snippet}
		{@render card(User, 'Identificação', identBody)}

		{#snippet emergBody()}
			{@render grid2(emergRows)}
		{/snippet}
		{#snippet emergRows()}
			{@render kv('Nome', p.emergencia_nome)}
			{@render kv('Parentesco', p.emergencia_parentesco)}
			<div class="col-span-2">{@render kv('Telefone', p.emergencia_tel, true)}</div>
		{/snippet}
		{@render card(Siren, 'Contato de emergência', emergBody)}

		{#snippet atendBody()}
			{@render grid2(atendRows)}
		{/snippet}
		{#snippet atendRows()}
			{@render kv('Tipo de atendimento', convLabel(p))}
			{@render kv('Convênio', p.convenio)}
			{@render kv('Carteirinha', p.carteirinha, true)}
			{@render kv('Validade', p.convenio_validade, true)}
			{@render kv('Médico solicitante', p.medico)}
			{@render kv('CRM', p.crm, true)}
			{@render kv('Profissional preferido', prefs.length ? prefs.join(', ') : '—')}
			{@render kv('Como conheceu', p.como_conheceu)}
			{@render kv('Profissão', p.profissao)}
			{@render kv('Empresa', p.empresa)}
		{/snippet}
		{@render card(Stethoscope, 'Atendimento & convênio', atendBody)}

		{#snippet consentBody()}
			<div class="flex flex-col gap-2.5">
				<div class="flex items-center gap-2.5 rounded-[10px] bg-teal-subtle px-3.5 py-2.5">
					<ShieldCheck size={17} class="text-teal-text" />
					<div class="min-w-0 flex-1">
						<div class="text-[13px] font-semibold">Tratamento de dados (LGPD)</div>
						<div class="text-[11.5px] text-muted">Prontuário, documentos e assistência</div>
					</div>
					<span class="text-[11.5px] font-bold {p.lgpd ? 'text-teal-text' : 'text-faint'}">{p.lgpd ? 'Autorizado' : 'Pendente'}</span>
				</div>
				<div class="flex items-center gap-2.5 rounded-[10px] border px-3.5 py-2.5 {p.comunicacao ? 'border-transparent bg-success/10' : 'border-edge bg-surface-2'}">
					{#if p.comunicacao}<BellRing size={17} class="text-success" />{:else}<BellOff size={17} class="text-faint" />{/if}
					<div class="min-w-0 flex-1">
						<div class="text-[13px] font-semibold">Comunicação e marketing</div>
						<div class="text-[11.5px] text-muted">WhatsApp, ligação e e-mail — lembretes e campanhas</div>
					</div>
					<span class="text-[11.5px] font-bold {p.comunicacao ? 'text-success' : 'text-faint'}">{p.comunicacao ? 'Autorizado' : 'Não autorizado'}</span>
				</div>
			</div>
		{/snippet}
		{@render card(ShieldCheck, 'Consentimentos', consentBody)}
	</div>

	<!-- Pacotes (Fatia 3): lista + ciclo de vida + criação (modal com prévia ao vivo). -->
	<PackageList packages={data.packages} {canManage} onNew={() => (criandoPacote = true)} />
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
