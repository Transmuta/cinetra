<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	import { CONTROL_CLASS, CONTROL_PX, CONTROL_H } from '$lib/components/Field.svelte';
	// Ficha do profissional, fiel a `renderProfForm` (:2955): painel de altura cheia com
	// cabeçalho (avatar + barra de progresso X/Y), coluna "SEÇÕES" com contador por seção,
	// cartões de seção com chip de ícone + subtítulo + contagem, e rodapé fixo. A grade de
	// horário e as EXCEÇÕES de data vivem dentro da seção "Horário" e são encenadas no estado
	// do form — tudo salva junto no `?/save`, que o `+page.server` orquestra.
	import { untrack } from 'svelte';
	import { enhance } from '$app/forms';
	import ConflictsModal from '$lib/components/scheduling/ConflictsModal.svelte';
	import { parseFutureConflicts, type FutureConflicts } from '$lib/scheduling-conflicts';
	import type { SubmitFunction } from '@sveltejs/kit';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import User from '@lucide/svelte/icons/user';
	import MapPin from '@lucide/svelte/icons/map-pin';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import FileText from '@lucide/svelte/icons/file-text';
	import CalendarClock from '@lucide/svelte/icons/calendar-clock';
	import Palette from '@lucide/svelte/icons/palette';
	import CalendarOff from '@lucide/svelte/icons/calendar-off';
	import Clock from '@lucide/svelte/icons/clock';
	import Check from '@lucide/svelte/icons/check';
	import Trash2 from '@lucide/svelte/icons/trash-2';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import SwitchToggle from '$lib/components/scheduling/SwitchToggle.svelte';
	import PeriodEditor from '$lib/components/scheduling/PeriodEditor.svelte';
	import ProfessionalHoursEditor from './ProfessionalHoursEditor.svelte';
	import { initials } from '$lib/format';
	import { avatarStyle } from '$lib/avatar';
	import {
		profColor,
		initialGrade,
		buildDays,
		hasAttendingDay,
		periodsWithinClinic,
		WEEKDAYS,
		type Professional,
		type ProfessionalException,
		type HoursRow,
		type GradeState
	} from '$lib/professionals';
	import { validateDayPeriods, formatDate, formatPeriods, type Period } from '$lib/scheduling';
	import { maskCpf, maskTel, maskCep, maskCnpj, maskAno, maskUf } from '$lib/masks';
	import { lookupCep, type CepStatus } from '$lib/cep';
	import { formatarTelefone, telefoneValido } from '$lib/telefone';

	let {
		professional = null,
		clinicHours,
		error = null,
		submitting = $bindable(false)
	}: {
		professional?: Professional | null;
		clinicHours: HoursRow[];
		error?: string | null;
		submitting?: boolean;
	} = $props();

	const editing = untrack(() => professional !== null);

	const ESPECIALIDADES = [
		'Traumato-Ortopedia', 'Neurologia', 'Pilates', 'Osteopatia', 'Desportiva',
		'RPG', 'Respiratória', 'Gerontologia', 'Pélvica', 'Aquática'
	];

	// Estado da ficha (untrack: nasce dos props, o profissional não muda durante a vida do
	// componente — remonta a cada navegação; convenção do TypeModal).
	let f = $state(
		untrack(() => ({
			nome: professional?.nome ?? '',
			nome_exibicao: professional?.nome_exibicao ?? '',
			nascimento: professional?.nascimento ?? '',
			// Canônico no banco (só dígitos), mascarado na tela — como o telefone abaixo. `maskCpf` é
			// idempotente, então o cadastro antigo que ainda tem máscara guardada também entra certo.
			cpf: maskCpf(professional?.cpf ?? ''),
			rg: professional?.rg ?? '',
			estado_civil: professional?.estado_civil ?? '',
			// Mascarado ao semear, como na ficha do paciente: se o valor gravado vier em E.164, o
			// `maskTel` do `oninput` conta os 13 dígitos, corta os dois últimos e promove o DDI a DDD.
			tel: formatarTelefone(professional?.tel) ?? '',
			email: professional?.email ?? '',
			cep: professional?.cep ?? '',
			endereco: professional?.endereco ?? '',
			numero: professional?.numero ?? '',
			complemento: professional?.complemento ?? '',
			bairro: professional?.bairro ?? '',
			cidade: professional?.cidade ?? '',
			uf: professional?.uf ?? '',
			emergencia_nome: professional?.emergencia_nome ?? '',
			emergencia_tel: formatarTelefone(professional?.emergencia_tel) ?? '',
			profissao: professional?.profissao ?? '',
			crefito: professional?.crefito ?? '',
			registro_uf: professional?.registro_uf ?? '',
			ano_conclusao: professional?.ano_conclusao ?? '',
			razao_social: professional?.razao_social ?? '',
			cnpj: professional?.cnpj ?? '',
			pix: professional?.pix ?? ''
		}))
	);
	let especialidades = $state<string[]>(untrack(() => professional?.especialidades ?? []));
	let vinculo = $state<string>(untrack(() => professional?.vinculo ?? ''));
	let corIndice = $state<number>(untrack(() => professional?.cor_indice ?? 1));
	let ativo = $state<boolean>(untrack(() => professional?.ativo ?? true));
	const originalAtivo = untrack(() => professional?.ativo ?? true);
	let segue = $state<boolean>(untrack(() => professional?.segue_horario_clinica ?? true));
	let grade = $state<GradeState>(untrack(() => initialGrade(professional, clinicHours)));

	// Exceções encenadas: item existente carrega `id`; novo não (o save cria/reconcilia).
	let exceptions = $state<ProfessionalException[]>(untrack(() => professional?.exceptions ?? []));
	const originalExceptionIds = untrack(() => (professional?.exceptions ?? []).map((e) => e.id));

	// Rascunho de nova exceção (fiel ao form do protótipo, :3152).
	let exData = $state('');
	let exNome = $state('');
	let exTipo = $state<'fechado' | 'horario'>('fechado');
	let exPeriods = $state<Period[]>([['08:00', '12:00']]);

	function addException() {
		if (!exData) return;
		const nome = exNome.trim() || (exTipo === 'horario' ? 'Horário especial' : 'Ausência');
		exceptions = [
			...exceptions,
			{ id: `new-${exData}-${exceptions.length}`, data: exData, nome, tipo: exTipo, periods: exTipo === 'horario' ? exPeriods : [] }
		];
		exData = '';
		exNome = '';
		exTipo = 'fechado';
		exPeriods = [['08:00', '12:00']];
	}
	function removeException(id: string) {
		exceptions = exceptions.filter((e) => e.id !== id);
	}
	const sortedExceptions = $derived([...exceptions].sort((a, b) => (a.data < b.data ? -1 : 1)));
	const newExceptionInvalid = $derived(exTipo === 'horario' && !validateDayPeriods(exPeriods).ok);

	function toggleEsp(t: string) {
		especialidades = especialidades.includes(t)
			? especialidades.filter((x) => x !== t)
			: [...especialidades, t];
	}

	// CEP → autopreenchimento (endereço/bairro/cidade/UF) pelo BFF, com status e guarda de
	// requisição obsoleta (o usuário pode mudar o CEP no meio da consulta), como no protótipo.
	let cepStatus = $state<CepStatus>(null);
	let cepReq = '';

	async function runCepLookup(cep: string) {
		const digits = cep.replace(/\D/g, '');
		if (digits.length !== 8) {
			cepStatus = null;
			return;
		}
		cepReq = digits;
		cepStatus = 'loading';
		const { status, address } = await lookupCep(digits);
		if (cepReq !== digits) return; // um novo CEP foi digitado durante a consulta
		cepStatus = status;
		if (status === 'ok' && address) {
			if (address.endereco) f.endereco = address.endereco;
			if (address.bairro) f.bairro = address.bairro;
			if (address.cidade) f.cidade = address.cidade;
			if (address.uf) f.uf = address.uf;
		}
	}

	function onCepInput(e: Event & { currentTarget: HTMLInputElement }) {
		f.cep = maskCep(e.currentTarget.value);
		runCepLookup(f.cep);
	}

	// ---- Validação: nome, telefone e horário obrigatórios ----
	const nomeOk = $derived(f.nome.trim().length > 0);
	// D6 (doc 64): o telefone entrou no mínimo, aqui e no paciente. A regra é a do servidor
	// (`TelObrigatorio` → `Dispatch.normalizar`), não uma segunda opinião — ver `telefoneValido`.
	const telOk = $derived(telefoneValido(f.tel));
	const attendanceOk = $derived(hasAttendingDay(segue, grade, clinicHours));
	const gradeInvalid = $derived(
		!segue &&
			WEEKDAYS.some(({ dow }) => {
				const day = grade[dow];
				if (!Array.isArray(day) || day.length === 0) return false;
				const clinic = clinicHours.find((r) => r.dow === dow)?.periods ?? [];
				return !validateDayPeriods(day).ok || !periodsWithinClinic(day as Period[], clinic);
			})
	);
	const canSave = $derived(nomeOk && telOk && attendanceOk && !gradeInvalid && !newExceptionInvalid);

	/**
	 * O que está errado AGORA, em uma frase — ou `null`. Sai do markup para cá (ACC-04) pelo mesmo
	 * motivo da ficha do paciente: o rodapé passou a distinguir problema (anunciado, visível em
	 * qualquer largura) de dica (silenciosa, só no desktop). A ordem é a de antes.
	 */
	const problema = $derived(
		error
			? error
			: gradeInvalid
				? 'Há horários fora do funcionamento da clínica.'
				: !attendanceOk
					? 'Defina ao menos um dia de atendimento.'
					: !telOk && f.tel.trim() !== ''
						? 'Telefone incompleto — use DDD + número.'
						: null
	);

	function fichaPayload() {
		const clean = Object.fromEntries(
			Object.entries(f).map(([k, v]) => [k, typeof v === 'string' && v.trim() === '' ? null : v])
		);
		return {
			...clean,
			nome: f.nome.trim(),
			especialidades,
			sub: especialidades[0] ?? null,
			vinculo: vinculo || null,
			cor_indice: corIndice,
			segue_horario_clinica: segue
		};
	}

	// A3/D12 — a ficha é a quarta porta de edição de horário (grade + folgas). Um 409
	// `future_conflicts` abre a mesma lista das telas de Horário e Exceções. Não há como forçar.
	let conflitos = $state<FutureConflicts | null>(null);

	const submit: SubmitFunction = () => {
		submitting = true;
		return async ({ result, update }) => {
			submitting = false;

			if (result.type === 'failure') {
				const achados = parseFutureConflicts(result.data?.code, result.data?.meta);
				if (achados) {
					conflitos = achados;
					// `update` sem reset para a ficha não perder o que a pessoa digitou enquanto
					// decide o que fazer com os conflitos.
					await update({ reset: false });
					return;
				}
			}

			conflitos = null;
			await update();
		};
	};


	// ---- Progresso e contagem por seção (fiel a `secCount`/`filled` :3014) ----
	const nonEmpty = (v: unknown) => (typeof v === 'string' ? v.trim() !== '' : !!v);

	const counts = $derived({
		ident: [f.nome, f.nome_exibicao, f.nascimento, f.cpf, f.rg, f.estado_civil].filter(nonEmpty).length,
		contato: [f.tel, f.email, f.cep, f.endereco, f.numero, f.complemento, f.bairro, f.cidade, f.uf, f.emergencia_nome, f.emergencia_tel].filter(nonEmpty).length,
		tecnicos: [f.profissao, f.crefito, f.registro_uf, f.ano_conclusao].filter(nonEmpty).length + (especialidades.length ? 1 : 0),
		contrato: [vinculo, f.razao_social, f.cnpj, f.pix].filter(nonEmpty).length,
		horario: segue ? 0 : 1,
		cor: 1 + (ativo ? 1 : 0)
	});
	const SECTIONS = [
		{ id: 'ident', icon: User, t: 'Identificação pessoal', sub: 'Dados básicos para o contrato', total: 6 },
		{ id: 'contato', icon: MapPin, t: 'Contato & localização', sub: 'Comunicação e endereço', total: 11 },
		{ id: 'tecnicos', icon: Stethoscope, t: 'Dados profissionais e técnicos', sub: 'Registro e aptidão técnica', total: 5 },
		{ id: 'contrato', icon: FileText, t: 'Contratuais & financeiros', sub: 'Vínculo, empresa e repasse', total: 4 },
		{ id: 'horario', icon: CalendarClock, t: 'Horário de atendimento', sub: 'Disponibilidade na agenda', total: 1 },
		{ id: 'cor', icon: Palette, t: 'Cor & status', sub: 'Aparência na agenda e situação', total: 2 }
	] as const;
	const totalKeys = SECTIONS.reduce((a, s) => a + s.total, 0);
	const totalFilled = $derived(Object.values(counts).reduce((a: number, b: number) => a + b, 0));

	// ---- Navegação lateral com scroll-spy ----
	let active = $state('ident');
	let scrollEl = $state<HTMLElement | null>(null);

	function onScroll() {
		if (!scrollEl) return;
		let cur = SECTIONS[0].id as string;
		for (const s of SECTIONS) {
			const el = document.getElementById(`sec-${s.id}`);
			if (el && el.getBoundingClientRect().top - scrollEl.getBoundingClientRect().top - 56 <= 0) cur = s.id;
		}
		active = cur;
	}
	function goSec(id: string) {
		document.getElementById(`sec-${id}`)?.scrollIntoView({ behavior: 'smooth', block: 'start' });
	}

	const inputCls = `${CONTROL_CLASS} ${CONTROL_PX} ${CONTROL_H} w-full`;
</script>

{#snippet label(text: string, required = false)}
	<span class="mb-1 block text-rotulo font-medium text-muted"
		>{text}{#if required}<span class="text-danger"> *</span>{/if}</span
	>
{/snippet}

{#snippet cardHead(icon: typeof User, t: string, sub: string, filled: number, total: number)}
	{@const Icon = icon}
	<div class="mb-4 flex items-center gap-3">
		<span class="grid size-[34px] shrink-0 place-items-center rounded-controle bg-accent-subtle text-accent-text">
			<Icon size={17} />
		</span>
		<div class="min-w-0 flex-1">
			<!-- `h2` pelo mesmo motivo da ficha do paciente (ACC-22): a hierarquia já era visual, só
			     não estava na marcação. As classes mandam, então o visual não muda. -->
			<h2 class="text-titulo font-bold">{t}</h2>
			<div class="text-meta text-faint">{sub}</div>
		</div>
		<span class="shrink-0 font-mono text-micro {filled ? 'text-accent-text' : 'text-faint'}">{filled}/{total}</span>
	</div>
{/snippet}

<form
	method="POST"
	action="?/save"
	use:enhance={submit}
	class="flex h-full flex-col bg-canvas"
>
	<input type="hidden" name="ficha" value={JSON.stringify(fichaPayload())} />
	<input type="hidden" name="days" value={JSON.stringify(buildDays(segue, grade, clinicHours))} />
	<input
		type="hidden"
		name="exceptions"
		value={JSON.stringify(exceptions.map((e) => ({ id: e.id.startsWith('new-') ? null : e.id, data: e.data, nome: e.nome, tipo: e.tipo, periods: e.periods })))}
	/>
	<input type="hidden" name="original_exception_ids" value={JSON.stringify(originalExceptionIds)} />
	<input type="hidden" name="ativo" value={ativo} />
	<input type="hidden" name="original_ativo" value={originalAtivo} />

	<!-- Cabeçalho do painel -->
	<header class="flex shrink-0 items-center gap-3.5 border-b border-edge bg-surface px-4 py-3 md:px-6">
		<a
			href="/profissionais"
			title="Voltar"
			class="grid size-[34px] shrink-0 place-items-center rounded-controle border border-edge bg-surface text-muted hover:bg-surface-2"
		>
			<ChevronLeft size={18} />
		</a>
		<span
			class="grid size-[42px] shrink-0 place-items-center rounded-full text-titulo font-bold"
			style={avatarStyle(corIndice)}
		>
			{f.nome.trim() ? initials(f.nome) : '?'}
		</span>
		<div class="min-w-0 flex-1">
			<div class="truncate text-titulo font-bold md:text-destaque">
				{f.nome.trim() || (editing ? 'Editar profissional' : 'Novo profissional')}
			</div>
			<div class="text-rotulo text-faint">
				{editing ? 'Editando cadastro profissional' : 'Cadastro de novo profissional'}
			</div>
		</div>
		<div class="hidden shrink-0 items-center gap-2.5 md:flex">
			<div class="h-1.5 w-[120px] overflow-hidden rounded-micro bg-surface-2">
				<div class="h-full bg-accent transition-all" style="width:{(totalFilled / totalKeys) * 100}%"></div>
			</div>
			<span class="font-mono text-meta text-faint">{totalFilled}/{totalKeys}</span>
		</div>
	</header>

	<div class="flex min-h-0 flex-1">
		<!-- SEÇÕES (desktop) -->
		<nav class="hidden w-[236px] shrink-0 overflow-y-auto border-r border-edge bg-surface p-3 md:block">
			<div class="px-2 pb-2 text-micro font-bold text-faint">SEÇÕES</div>
			<div class="flex flex-col gap-0.5">
				{#each SECTIONS as s (s.id)}
					{@const on = active === s.id}
					{@const cnt = counts[s.id as keyof typeof counts]}
					<button
						type="button"
						onclick={() => goSec(s.id)}
						class="flex items-center gap-2.5 rounded-controle px-2.5 py-2 text-left text-corpo {on
							? 'bg-accent-subtle font-bold text-accent-text'
							: 'font-medium text-muted hover:bg-surface-2'}"
					>
						<s.icon size={16} />
						<span class="min-w-0 flex-1 truncate">{s.t}</span>
						{#if cnt}<span class="size-[7px] shrink-0 rounded-full bg-accent"></span>{/if}
					</button>
				{/each}
			</div>
		</nav>

		<!-- Cartões -->
		<div bind:this={scrollEl} onscroll={onScroll} class="min-h-0 flex-1 overflow-y-auto p-4 md:p-6">
			<div class="mx-auto max-w-[720px] space-y-3.5 pb-4">
				<!-- 1. Identificação -->
				<section id="sec-ident" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(User, SECTIONS[0].t, SECTIONS[0].sub, counts.ident, SECTIONS[0].total)}
					<label class="mb-3 block">
						{@render label('Nome completo', true)}
						<input bind:value={f.nome} placeholder="Nome do profissional" class={inputCls} />
					</label>
					<label class="mb-3 block">
						{@render label('Nome de exibição / tratamento (opcional)')}
						<input bind:value={f.nome_exibicao} placeholder="ex.: Dra. Marina" class={inputCls} />
					</label>
					<div class="grid grid-cols-1 gap-3 md:grid-cols-2">
						<label class="block">
							{@render label('Data de nascimento')}
							<input type="date" bind:value={f.nascimento} class={inputCls} />
						</label>
						<label class="block">
							{@render label('CPF')}
							<input value={f.cpf} oninput={(e) => (f.cpf = maskCpf(e.currentTarget.value))} inputmode="numeric" placeholder="000.000.000-00" class="{inputCls} font-mono" />
						</label>
						<label class="block">
							{@render label('RG')}
							<input bind:value={f.rg} placeholder="Órgão emissor incl." class="{inputCls} font-mono" />
						</label>
						<label class="block">
							{@render label('Estado civil')}
							<select bind:value={f.estado_civil} class={inputCls}>
								<option value="">Selecione…</option>
								<option>Solteiro(a)</option><option>Casado(a)</option>
								<option>Divorciado(a)</option><option>Viúvo(a)</option>
							</select>
						</label>
					</div>
				</section>

				<!-- 2. Contato & localização -->
				<section id="sec-contato" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(MapPin, SECTIONS[1].t, SECTIONS[1].sub, counts.contato, SECTIONS[1].total)}
					<div class="grid grid-cols-1 gap-3 md:grid-cols-2">
						<label class="block">
							{@render label('Celular / WhatsApp', true)}
							<input value={f.tel} oninput={(e) => (f.tel = maskTel(e.currentTarget.value))} inputmode="tel" placeholder="(11) 90000-0000" class="{inputCls} font-mono" />
						</label>
						<label class="block">
							{@render label('E-mail (contato)')}
							<input bind:value={f.email} placeholder="email@exemplo.com" class={inputCls} />
						</label>
						<label class="block">
							{@render label('CEP')}
							<input value={f.cep} oninput={onCepInput} onblur={() => runCepLookup(f.cep)} inputmode="numeric" placeholder="00000-000" class="{inputCls} font-mono" />
							{#if cepStatus}
								<span
									class="mt-1 block text-meta {cepStatus === 'ok'
										? 'text-accent-text'
										: cepStatus === 'loading'
											? 'text-muted'
											: 'text-danger'}"
								>
									{cepStatus === 'loading'
										? 'Buscando endereço…'
										: cepStatus === 'ok'
											? 'Endereço preenchido pelo CEP'
											: cepStatus === 'notfound'
												? 'CEP não encontrado — preencha manualmente'
												: 'Não foi possível consultar o CEP agora'}
								</span>
							{/if}
						</label>
						<label class="block">
							{@render label('Endereço')}
							<input bind:value={f.endereco} placeholder="Preenchido pelo CEP" class={inputCls} />
						</label>
						<label class="block">
							{@render label('Bairro')}
							<input bind:value={f.bairro} class={inputCls} />
						</label>
						<div class="grid grid-cols-3 gap-2">
							<label class="block">
								{@render label('Nº')}
								<input bind:value={f.numero} class={inputCls} />
							</label>
							<label class="block">
								{@render label('UF')}
								<input value={f.uf} oninput={(e) => (f.uf = maskUf(e.currentTarget.value))} maxlength="2" class="{inputCls} uppercase" />
							</label>
							<label class="block">
								{@render label('Cidade')}
								<input bind:value={f.cidade} class={inputCls} />
							</label>
						</div>
						<label class="block">
							{@render label('Complemento')}
							<input bind:value={f.complemento} placeholder="Apto / bloco" class={inputCls} />
						</label>
						<label class="block">
							{@render label('Contato de emergência')}
							<input bind:value={f.emergencia_nome} placeholder="Nome e parentesco" class={inputCls} />
						</label>
						<label class="block">
							{@render label('Telefone de emergência')}
							<input value={f.emergencia_tel} oninput={(e) => (f.emergencia_tel = maskTel(e.currentTarget.value))} inputmode="tel" placeholder="(11) 90000-0000" class="{inputCls} font-mono" />
						</label>
					</div>
				</section>

				<!-- 3. Dados técnicos -->
				<section id="sec-tecnicos" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(Stethoscope, SECTIONS[2].t, SECTIONS[2].sub, counts.tecnicos, SECTIONS[2].total)}
					<div class="mb-3 grid grid-cols-1 gap-3 md:grid-cols-2">
						<label class="block">
							{@render label('Profissão / formação')}
							<select bind:value={f.profissao} class={inputCls}>
								<option value="">Selecione…</option>
								<option>Fisioterapia</option><option>Educação Física</option>
								<option>Terapia Ocupacional</option><option>Fonoaudiologia</option><option>Outra</option>
							</select>
						</label>
						<label class="block">
							{@render label('Nº de registro (CREFITO / CRM)')}
							<input bind:value={f.crefito} placeholder="CREFITO 3/000000-F" class="{inputCls} font-mono" />
						</label>
						<label class="block">
							{@render label('UF do conselho')}
							<input value={f.registro_uf} oninput={(e) => (f.registro_uf = maskUf(e.currentTarget.value))} maxlength="2" class="{inputCls} uppercase" />
						</label>
						<label class="block">
							{@render label('Ano de conclusão')}
							<input value={f.ano_conclusao} oninput={(e) => (f.ano_conclusao = maskAno(e.currentTarget.value))} inputmode="numeric" placeholder="AAAA" class="{inputCls} font-mono" />
						</label>
					</div>
					{@render label('Especialidades / áreas de atuação')}
					<div class="flex flex-wrap gap-1.5">
						{#each ESPECIALIDADES as t (t)}
							{@const on = especialidades.includes(t)}
							<button
								type="button"
								onclick={() => toggleEsp(t)}
								class="flex items-center gap-1.5 rounded-full border px-2.5 py-1.5 text-rotulo font-semibold {on
									? 'border-transparent bg-accent-subtle text-accent-text'
									: 'border-edge bg-surface text-ink hover:bg-surface-2'}"
							>
								{t}{#if on}<Check size={13} />{/if}
							</button>
						{/each}
					</div>
				</section>

				<!-- 4. Contratuais & financeiros -->
				<section id="sec-contrato" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(FileText, SECTIONS[3].t, SECTIONS[3].sub, counts.contrato, SECTIONS[3].total)}
					{@render label('Tipo de vínculo')}
					<div class="mb-3 flex gap-2">
						{#each [['autonomo', 'Autônomo'], ['pj', 'PJ'], ['clt', 'CLT']] as [val, lbl] (val)}
							<button
								type="button"
								onclick={() => (vinculo = val)}
								class="flex-1 rounded-controle border py-2 text-rotulo font-semibold {vinculo === val
									? 'border-transparent bg-primary text-on-primary'
									: 'border-edge bg-surface text-ink hover:bg-surface-2'}"
							>
								{lbl}
							</button>
						{/each}
					</div>
					{#if vinculo === 'pj'}
						<div class="mb-3 grid grid-cols-1 gap-3 md:grid-cols-2">
							<label class="block">
								{@render label('Razão social')}
								<input bind:value={f.razao_social} placeholder="Empresa LTDA" class={inputCls} />
							</label>
							<label class="block">
								{@render label('CNPJ')}
								<input value={f.cnpj} oninput={(e) => (f.cnpj = maskCnpj(e.currentTarget.value))} placeholder="00.000.000/0000-00" class="{inputCls} font-mono" />
							</label>
						</div>
					{/if}
					<div class="mb-2 text-meta font-bold text-faint">Dados bancários para repasse</div>
					<label class="block">
						{@render label('Chave PIX')}
						<input bind:value={f.pix} placeholder="CPF, e-mail, telefone ou aleatória" class={inputCls} />
					</label>
				</section>

				<!-- 5. Horário de atendimento (grade + exceções) -->
				<section id="sec-horario" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(CalendarClock, SECTIONS[4].t, SECTIONS[4].sub, counts.horario, SECTIONS[4].total)}

					<div class="mb-3 flex items-center gap-3 rounded-controle border p-3 {segue ? 'border-accent bg-accent-subtle' : 'border-edge'}">
						<SwitchToggle checked={segue} label="Seguir o horário da clínica" onchange={() => (segue = !segue)} />
						<div>
							<div class="text-corpo font-semibold">Seguir o horário da clínica</div>
							<div class="text-meta text-muted">
								{segue
									? 'O profissional atende exatamente no horário da clínica.'
									: 'Defina o horário do profissional — sempre dentro do funcionamento da clínica.'}
							</div>
						</div>
					</div>

					{#if !segue}
						<ProfessionalHoursEditor {clinicHours} {grade} onchange={(g) => (grade = g)} />
						{#if !attendanceOk}
							<p class="mt-2 flex items-center gap-1.5 text-rotulo font-semibold text-danger">
								<TriangleAlert size={14} /> Defina ao menos um dia de atendimento (horário é obrigatório).
							</p>
						{/if}
					{/if}

					<!-- Exceções de data (dentro da seção Horário, como o protótipo) -->
					<div class="mt-4 border-t border-edge pt-4">
						<div class="mb-0.5 flex items-center gap-2">
							<CalendarOff size={15} class="text-muted" />
							<span class="text-corpo font-semibold">Exceções de data</span>
						</div>
						<p class="mb-3 text-meta text-muted">
							Folgas, férias, congressos ou um horário pontual só deste profissional. Valem sobre o
							horário semanal.
						</p>

						<div class="mb-3 rounded-cartao border border-edge bg-surface-2 p-3">
							<div class="mb-2.5 flex flex-wrap gap-2">
								<input
									type="date"
									bind:value={exData}
									aria-label="Data da exceção"
									class="{inputCls} max-w-[170px]"
								/>
								<input
									bind:value={exNome}
									placeholder="Descrição (ex.: férias, congresso)"
									class="{inputCls} min-w-0 flex-1"
								/>
							</div>
							<div class="mb-2.5 flex gap-1.5" role="group" aria-label="Tipo de exceção">
								<button
									type="button"
									onclick={() => (exTipo = 'fechado')}
									aria-pressed={exTipo === 'fechado'}
									class="flex-1 rounded-controle border px-2 py-[7px] text-rotulo font-semibold {exTipo === 'fechado'
										? 'border-accent bg-accent-subtle text-accent-text'
										: 'border-edge bg-surface text-muted'}"
								>
									Não atende no dia
								</button>
								<button
									type="button"
									onclick={() => (exTipo = 'horario')}
									aria-pressed={exTipo === 'horario'}
									class="flex-1 rounded-controle border px-2 py-[7px] text-rotulo font-semibold {exTipo === 'horario'
										? 'border-accent bg-accent-subtle text-accent-text'
										: 'border-edge bg-surface text-muted'}"
								>
									Horário específico
								</button>
							</div>
							{#if exTipo === 'horario'}
								<div class="mb-2.5">
									<p class="mb-1.5 text-meta text-muted">Períodos de atendimento neste dia:</p>
									<PeriodEditor periods={exPeriods} onchange={(p) => (exPeriods = p)} />
								</div>
							{/if}
							<button
								type="button"
								onclick={addException}
								disabled={!exData || newExceptionInvalid}
								class="rounded-controle bg-primary px-3.5 py-2 text-corpo font-semibold text-on-primary hover:bg-primary-hover disabled:opacity-60"
							>
								Adicionar exceção
							</button>
						</div>

						{#if sortedExceptions.length}
							<div class="overflow-hidden rounded-cartao border border-edge">
								{#each sortedExceptions as e (e.id)}
									{@const isH = e.tipo === 'horario'}
									<div class="flex items-center gap-3 border-t border-edge px-3 py-2.5 first:border-t-0">
										{#if isH}<Clock size={16} class="text-accent-text" />{:else}<CalendarOff size={16} class="text-danger" />{/if}
										<span class="w-[82px] shrink-0 font-mono text-meta">{formatDate(e.data)}</span>
										<div class="min-w-0 flex-1">
											<div class="truncate text-corpo">{e.nome}</div>
											<div class="font-mono text-micro {isH ? 'text-accent-text' : 'text-danger'}">
												{isH ? formatPeriods(e.periods) : 'Não atende o dia inteiro'}
											</div>
										</div>
										<button
											type="button"
											onclick={() => removeException(e.id)}
											title="Remover"
											class="grid size-7.5 place-items-center rounded-controle border border-edge bg-surface text-danger hover:bg-surface-2"
										>
											<Trash2 size={14} />
										</button>
									</div>
								{/each}
							</div>
						{/if}
					</div>
				</section>

				<!-- 6. Cor & status -->
				<section id="sec-cor" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(Palette, SECTIONS[5].t, SECTIONS[5].sub, counts.cor, SECTIONS[5].total)}
					<div class="mb-1 text-rotulo font-medium text-muted">Cor do avatar na agenda</div>
					<div class="mb-4 flex flex-wrap gap-2.5">
						{#each [1, 2, 3, 4, 5, 6, 7] as ci (ci)}
							<button
								type="button"
								onclick={() => (corIndice = ci)}
								aria-label="Cor {ci}"
								aria-pressed={corIndice === ci}
								class="grid size-9 place-items-center rounded-full ring-2 ring-offset-2 ring-offset-surface {corIndice === ci ? 'ring-ink' : 'ring-transparent'}"
								style={avatarStyle(ci)}
							>
								{#if corIndice === ci}<Check size={16} color="white" />{/if}
							</button>
						{/each}
					</div>

					<!-- Situação (arquivar): fora de circulação some da lista de ativos, sem apagar. -->
					<div class="flex items-center gap-3 border-t border-edge pt-4">
						<SwitchToggle checked={ativo} label="Profissional ativo" onchange={() => (ativo = !ativo)} />
						<div>
							<div class="text-corpo font-semibold">{ativo ? 'Profissional ativo' : 'Inativo (arquivado)'}</div>
							<div class="text-meta text-muted">
								{ativo
									? 'Aparece na agenda e na lista de ativos.'
									: 'Fica arquivado — some dos ativos, sem apagar o histórico.'}
							</div>
						</div>
					</div>
				</section>
			</div>
		</div>
	</div>

	<!-- Rodapé fixo -->
	<footer class="flex shrink-0 items-center gap-3 border-t border-edge bg-surface px-4 py-3 md:px-6">
		<!-- ACC-04 (doc 83): o par do rodapé da ficha do paciente — problema é `role="alert"` e
		     visível em qualquer largura; dica segue só no desktop e sem papel. -->
		{#if problema}
			<span role="alert" class="flex flex-1 items-center gap-1.5 text-rotulo text-danger">
				<TriangleAlert size={14} class="shrink-0" /> {problema}
			</span>
		{:else}
			<!-- D6: o mínimo deixou de ser só o nome. A frase antiga ("apenas o nome") passou a
			     mentir no instante em que a validação entrou, e uma dica que mente é pior que
			     nenhuma: manda a pessoa clicar em salvar para descobrir o contrário. -->
			<span class="hidden flex-1 items-center gap-1.5 text-rotulo text-faint md:flex">
				Nome e telefone são obrigatórios — o resto pode ficar para depois.
			</span>
			<div class="flex-1 md:hidden"></div>
		{/if}
		<a
			href="/profissionais"
			class="rounded-controle border border-edge bg-surface px-4 py-2 text-corpo font-semibold text-ink hover:bg-surface-2"
			>Cancelar</a
		>
		<Button type="submit"
			emVoo={submitting}
			disabled={!canSave}
		>
			{editing ? 'Salvar' : 'Cadastrar profissional'}
		</Button>
	</footer>
</form>

{#if conflitos}
	<ConflictsModal {conflitos} onClose={() => (conflitos = null)} />
{/if}
