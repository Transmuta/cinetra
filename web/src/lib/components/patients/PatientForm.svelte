<script lang="ts">
	import Button from '$lib/components/Button.svelte';
	import { CONTROL_CLASS, CONTROL_PX, CONTROL_H } from '$lib/components/Field.svelte';
	// Ficha do paciente, fiel a `renderPacienteForm` (:2010): painel de altura cheia com
	// cabeçalho (avatar + barra de progresso X/Y), coluna "SEÇÕES" com contador por seção,
	// cartões de seção com chip de ícone + subtítulo + contagem, e rodapé fixo. São 8 seções
	// cadastrais — sem cor/situação (o arquivar mora na ficha, não aqui). Tudo salva no
	// `?/save`, que o `+page.server` orquestra.
	import { untrack, onDestroy } from 'svelte';
	import { enhance } from '$app/forms';
	import { ERRO_DE_REDE } from '$lib/forms.svelte';
	import type { SubmitFunction } from '@sveltejs/kit';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import User from '@lucide/svelte/icons/user';
	import MapPin from '@lucide/svelte/icons/map-pin';
	import Siren from '@lucide/svelte/icons/siren';
	import Briefcase from '@lucide/svelte/icons/briefcase';
	import CreditCard from '@lucide/svelte/icons/credit-card';
	import BadgeCheck from '@lucide/svelte/icons/badge-check';
	import Stethoscope from '@lucide/svelte/icons/stethoscope';
	import ShieldCheck from '@lucide/svelte/icons/shield-check';
	import Check from '@lucide/svelte/icons/check';
	import X from '@lucide/svelte/icons/x';
	import Plus from '@lucide/svelte/icons/plus';
	import UserSearch from '@lucide/svelte/icons/user-search';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
	import { initials } from '$lib/format';
	import { avatarStyle } from '$lib/avatar';
	import { patientColor, idade, stripTitle, emailValido, nascimentoValido, type Patient } from '$lib/patients';
	import { profColor, type Professional } from '$lib/professionals';
	import { maskCpf, maskTel, maskCep, maskMy, maskUf } from '$lib/masks';
	import { lookupCep, type CepStatus } from '$lib/cep';
	import { formatarTelefone, recebeWhatsapp, telefoneValido } from '$lib/telefone';
	import { isValidCpf } from '$lib/cpf';

	let {
		patient = null,
		professionals = [],
		error = null,
		submitting = $bindable(false)
	}: {
		patient?: Patient | null;
		professionals?: Professional[];
		error?: string | null;
		submitting?: boolean;
	} = $props();

	const editing = untrack(() => patient !== null);

	// Estado da ficha (untrack: nasce dos props; o paciente não muda durante a vida do componente
	// — remonta a cada navegação; convenção do ProfessionalForm/TypeModal).
	let f = $state(
		untrack(() => ({
			nome: patient?.nome ?? '',
			nome_social: patient?.nome_social ?? '',
			// Canônico no banco (só dígitos), mascarado na tela — a mesma divisão do telefone logo
			// abaixo e do CNPJ da clínica. `maskCpf` é idempotente, então a ficha antiga que ainda
			// tem máscara guardada também entra certa.
			cpf: maskCpf(patient?.cpf ?? ''),
			rg: patient?.rg ?? '',
			genero: patient?.genero ?? '',
			estado_civil: patient?.estado_civil ?? '',
			nascimento: patient?.nascimento ?? '',
			responsavel: patient?.responsavel ?? '',
			// Mascarado ao semear: o banco guarda E.164 (`NormalizeTel`, doc 52 §9) e o campo é o
			// mesmo que a recepção lê. Sem isto a edição reabria com `+5511987654321` — e pior:
			// o `maskTel` do `oninput` conta 13 dígitos, corta os dois últimos e promove o DDI a
			// DDD (`(55) 11987-6543`) no primeiro toque de tecla.
			tel: formatarTelefone(patient?.tel) ?? '',
			email: patient?.email ?? '',
			cep: patient?.cep ?? '',
			endereco: patient?.endereco ?? '',
			numero: patient?.numero ?? '',
			complemento: patient?.complemento ?? '',
			bairro: patient?.bairro ?? '',
			cidade: patient?.cidade ?? '',
			uf: patient?.uf ?? '',
			emergencia_nome: patient?.emergencia_nome ?? '',
			emergencia_parentesco: patient?.emergencia_parentesco ?? '',
			emergencia_tel: formatarTelefone(patient?.emergencia_tel) ?? '',
			profissao: patient?.profissao ?? '',
			empresa: patient?.empresa ?? '',
			medico: patient?.medico ?? '',
			crm: patient?.crm ?? '',
			como_conheceu: patient?.como_conheceu ?? '',
			convenio: patient?.convenio ?? '',
			carteirinha: patient?.carteirinha ?? '',
			convenio_validade: patient?.convenio_validade ?? ''
		}))
	);
	let atendTipo = $state<string>(untrack(() => patient?.atend_tipo ?? 'particular'));
	let prefs = $state<string[]>(untrack(() => patient?.prefs ?? []));
	let tags = $state<string[]>(untrack(() => patient?.tags ?? []));
	let lgpd = $state<boolean>(untrack(() => patient?.lgpd ?? false));
	// **`?? true`** (doc 52 §11.1/§11.2, decisão de 2026-07-27). O `??` só age na CRIAÇÃO — numa
	// edição, `patient.comunicacao` existe e o valor salvo manda.
	//
	// Nasce autorizado porque o que sai por este canal é operacional: confirmar e lembrar de uma
	// sessão que o próprio paciente marcou é execução do serviço contratado (LGPD, Art. 7º, V),
	// não marketing. Mudar o default do recurso Ash sem mudar aqui não mudaria nada: todo paciente
	// nasce por este formulário, que **sempre manda o valor**.
	//
	// O `lgpd` logo acima continua `?? false` de propósito: aquele é o termo de tratamento de
	// dado, é declaração de que a clínica colheu o aceite, e presumi-lo é o que a lei não deixa.
	let comunicacao = $state<boolean>(untrack(() => patient?.comunicacao ?? true));
	const corIndice = untrack(() => patient?.cor_indice ?? 1);
	let showResp = $state(false);
	let temConvenio = $state(
		untrack(() => !!(patient?.convenio || patient?.carteirinha || patient?.convenio_validade))
	);

	// Idade derivada da data ISO; o campo de responsável legal aparece p/ menor de idade (fiel
	// a `needResp` :2025).
	const idadeVal = $derived(idade(f.nascimento || null));
	const nascLabel = $derived('Data de nascimento' + (idadeVal !== null ? ` · ${idadeVal} anos` : ''));
	const needResp = $derived(
		(idadeVal !== null && idadeVal < 18) || f.responsavel.trim() !== '' || showResp
	);

	// Aviso de duplicado. Deixou de ser "possível" (`dup` :2014, decisão original da fatia): desde
	// 2026-07-29 o servidor **recusa** CPF, telefone ou e-mail repetido na clínica. O aviso existe
	// para a recepção descobrir isso ao digitar o campo, e não depois de preencher a ficha inteira.
	//
	// Quem decide o que é duplicado é `/api/patients/lookup`, que confere os três campos e compara
	// a forma canônica dos dois lados. Antes o cliente escolhia UM termo, com o CPF na frente — e
	// com o CPF preenchido, telefone repetido não era consultado.
	let dup = $state<{ nome: string; campo: string; ativo: boolean } | null>(null);
	let dupReq = '';
	let dupTimer: ReturnType<typeof setTimeout> | undefined;

	interface DupMatch {
		id: string;
		nome: string;
		campo: string;
		ativo: boolean;
	}

	async function lookupDup(cpf: string, tel: string, email: string, nome: string, nascimento: string) {
		// Só o que está COMPLETO viaja: CPF pela metade não identifica ninguém, e uma consulta por
		// tecla digitada seria desperdício. O servidor repete estas guardas (é ele quem decide o que
		// é duplicado, e o endpoint é alcançável sem passar por aqui); a cópia é o mesmo espelho
		// deliberado de `telefoneValido` — a tela adianta, o servidor decide.
		const params = new URLSearchParams();
		if (cpf.replace(/\D/g, '').length === 11) params.set('cpf', cpf.trim());
		if (telefoneValido(tel)) params.set('tel', tel.trim());
		if (emailValido(email.trim())) params.set('email', email.trim());

		// Nome + nascimento (AN-10) é a heurística de quem não tem documento: só vale quando os dois
		// estão preenchidos, e o servidor só a usa quando não há identificação completa.
		if (nome.trim().length >= 3 && /^\d{4}-\d{2}-\d{2}$/.test(nascimento)) {
			params.set('nome', nome.trim());
			params.set('nascimento', nascimento);
		}

		if ([...params.keys()].length === 0) {
			dup = null;
			return;
		}

		// Na edição, a própria ficha não é duplicado de si mesma.
		if (patient?.id) params.set('exclude', patient.id);

		const url = `/api/patients/lookup?${params}`;
		dupReq = url;

		try {
			const res = await fetch(url);
			if (!res.ok || dupReq !== url) return; // resposta obsoleta: o campo mudou no meio

			const { match } = (await res.json()) as { match: DupMatch | null };
			dup = match ? { nome: match.nome, campo: match.campo, ativo: match.ativo } : null;
		} catch {
			// Rede fora: o aviso é conveniência, nunca barreira — quem recusa é o servidor.
		}
	}

	// Debounce: o documento é digitado aos poucos, não vale uma consulta por tecla.
	function scheduleDupCheck() {
		clearTimeout(dupTimer);
		dupTimer = setTimeout(() => lookupDup(f.cpf, f.tel, f.email, f.nome, f.nascimento), 400);
	}

	// Timer órfão depois de sair do formulário só gastaria uma consulta à toa.
	onDestroy(() => clearTimeout(dupTimer));

	// Preferência de profissional (chips dos ativos) — `renderPacienteForm` seção 'clinico'.
	const activeProfs = $derived(professionals.filter((p) => p.ativo));
	function togglePref(id: string) {
		prefs = prefs.includes(id) ? prefs.filter((x) => x !== id) : [...prefs, id];
	}

	// Tags / condições clínicas — chip input (Enter/vírgula adiciona; Backspace remove a última).
	const SUGG = [
		'lombalgia', 'cervicalgia', 'pós-op joelho', 'pós-op ombro', 'tendinite', 'escoliose',
		'hérnia de disco', 'LER/DORT', 'entorse tornozelo', 'fortalecimento', 'reabilitação esportiva', 'gestante'
	];
	let tagInput = $state('');
	function addTag(raw: string) {
		const t = (raw ?? '').trim().replace(/,+$/, '').trim();
		if (!t || tags.includes(t)) {
			tagInput = '';
			return;
		}
		tags = [...tags, t];
		tagInput = '';
	}
	function removeTag(t: string) {
		tags = tags.filter((x) => x !== t);
	}
	function onTagKey(e: KeyboardEvent & { currentTarget: HTMLInputElement }) {
		if (e.key === 'Enter' || e.key === ',') {
			e.preventDefault();
			addTag(e.currentTarget.value);
		} else if (e.key === 'Backspace' && !e.currentTarget.value && tags.length) {
			removeTag(tags[tags.length - 1]);
		}
	}

	// CEP → autopreenchimento pelo BFF, com status e guarda de requisição obsoleta.
	let cepStatus = $state<CepStatus>(null);
	let cepReq = '';
	async function runCepLookup(cep: string) {
		const d = cep.replace(/\D/g, '');
		if (d.length !== 8) {
			cepStatus = null;
			return;
		}
		cepReq = d;
		cepStatus = 'loading';
		const { status, address } = await lookupCep(d);
		if (cepReq !== d) return;
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

	// ---- Validação: nome e telefone são obrigatórios ----
	const nomeOk = $derived(f.nome.trim().length > 0);
	// D6 (doc 64) / `TelObrigatorio`: o rótulo já trazia o asterisco, mas o botão salvava assim
	// mesmo e o 422 só aparecia depois da viagem. A regra é a do servidor — ver `telefoneValido`.
	const telOk = $derived(telefoneValido(f.tel));

	// AN-11 (D10: **barra no salvar**). Os três seguem opcionais — vazio passa; preenchido tem
	// de ser válido. A régua é a do servidor (`CampoValido`); aqui ela só chega antes da viagem.
	const cpfOk = $derived(f.cpf.trim() === '' || isValidCpf(f.cpf));
	const emailOk = $derived(f.email.trim() === '' || emailValido(f.email.trim()));
	const nascOk = $derived(f.nascimento === '' || nascimentoValido(f.nascimento));
	const identOk = $derived(cpfOk && emailOk && nascOk);

	/**
	 * Rede fora não passa pelo `update` (doc 88, A-10).
	 *
	 * `update()` chama o `applyAction`, e para `result.type === 'error'` isso troca a página pela
	 * tela de erro — levando junto os 31 campos que a pessoa acabou de digitar. Aqui a falha vira
	 * uma frase no rodapé, que já é `role="alert"`, e o formulário **continua montado**.
	 *
	 * Declarado ANTES de `problema` porque é ele quem o lê — em Svelte 5 um `$derived` que
	 * referencia um `$state` declarado abaixo não compila.
	 */
	let erroRede = $state<string | null>(null);

	/**
	 * O que está errado AGORA, em uma frase — ou `null` se nada está.
	 *
	 * Sai do markup para cá (ACC-04) porque o rodapé passou a tratar problema e dica como coisas
	 * diferentes: o problema é `role="alert"` e aparece em qualquer largura; a dica, não. A ordem é
	 * a mesma de antes — o erro do servidor primeiro, porque ele é o que a pessoa acabou de causar.
	 */
	const problema = $derived(
		erroRede
			? erroRede
			: error
			? error
			: !telOk && f.tel.trim() !== ''
				? 'Telefone incompleto — use DDD + número.'
				: !cpfOk
					? 'CPF inválido — confira os dígitos.'
					: !emailOk
						? 'E-mail inválido — use nome@dominio.'
						: !nascOk
							? 'Data de nascimento inválida.'
							: null
	);

	function fichaPayload() {
		const clean = Object.fromEntries(
			Object.entries(f).map(([k, v]) => [k, typeof v === 'string' && v.trim() === '' ? null : v])
		);
		return {
			...clean,
			nome: f.nome.trim(),
			atend_tipo: atendTipo,
			prefs,
			tags,
			lgpd,
			comunicacao,
			cor_indice: corIndice
		};
	}

	const submit: SubmitFunction = () => {
		submitting = true;
		erroRede = null;
		return async ({ result, update }) => {
			submitting = false;
			if (result.type === 'error') {
				erroRede = ERRO_DE_REDE;
				return;
			}
			await update();
		};
	};

	// ---- Progresso e contagem por seção (fiel a `secCount`/`filled` :2038) ----
	const nonEmpty = (v: unknown) => (typeof v === 'string' ? v.trim() !== '' : !!v);
	const counts = $derived({
		ident: [f.nome, f.nome_social, f.tel, f.cpf, f.nascimento, f.genero, f.estado_civil, f.rg].filter(nonEmpty).length,
		contato: [f.email, f.cep, f.endereco, f.bairro, f.cidade, f.uf, f.numero, f.complemento].filter(nonEmpty).length,
		emergencia: [f.emergencia_nome, f.emergencia_parentesco, f.emergencia_tel].filter(nonEmpty).length,
		profissional: [f.profissao, f.empresa].filter(nonEmpty).length,
		atendimento: [f.medico, f.crm, f.como_conheceu].filter(nonEmpty).length,
		convenio: [f.convenio, f.carteirinha, f.convenio_validade].filter(nonEmpty).length,
		clinico: (prefs.length ? 1 : 0) + (tags.length ? 1 : 0),
		consentimento: (lgpd ? 1 : 0) + (comunicacao ? 1 : 0)
	});
	const SECTIONS = [
		{ id: 'ident', icon: User, t: 'Identificação', sub: 'Nome, contato principal e documento', total: 8 },
		{ id: 'contato', icon: MapPin, t: 'Endereço & e-mail', sub: 'E-mail e endereço residencial', total: 8 },
		{ id: 'emergencia', icon: Siren, t: 'Emergência', sub: 'Quem acionar se necessário', total: 3 },
		{ id: 'profissional', icon: Briefcase, t: 'Dados profissionais', sub: 'Ocupação e vínculo', total: 2 },
		{ id: 'atendimento', icon: CreditCard, t: 'Atendimento', sub: 'Como a clínica cobra e encaminhamento', total: 3 },
		{ id: 'convenio', icon: BadgeCheck, t: 'Convênio do paciente', sub: 'Plano de saúde — útil também para encaminhar', total: 3 },
		{ id: 'clinico', icon: Stethoscope, t: 'Preferências clínicas', sub: 'Profissional preferido e condições', total: 2 },
		{ id: 'consentimento', icon: ShieldCheck, t: 'Consentimento', sub: 'Autorizações LGPD e contato', total: 2 }
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
			<!-- `h2`, e não `div` (ACC-22, doc 83): a hierarquia visual já existia — o que faltava era
			     dizê-la na marcação, para navegar a ficha por headings (que é como leitor de tela
			     varre página). O preflight do Tailwind zera margem e tamanho do `h2`, então as
			     classes mandam e nada muda na tela. `h2` porque o `h1` é o título da seção, no topbar. -->
			<h2 class="text-titulo font-bold">{t}</h2>
			<div class="text-meta text-faint">{sub}</div>
		</div>
		<span class="shrink-0 font-mono text-micro {filled ? 'text-accent-text' : 'text-faint'}">{filled}/{total}</span>
	</div>
{/snippet}

<form method="POST" action="?/save" use:enhance={submit} class="flex h-full flex-col bg-canvas">
	<input type="hidden" name="ficha" value={JSON.stringify(fichaPayload())} />

	<!-- Cabeçalho do painel -->
	<header class="flex shrink-0 items-center gap-3.5 border-b border-edge bg-surface px-4 py-3 md:px-6">
		<a
			href={editing ? `/pacientes/${patient?.id}` : '/pacientes'}
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
				{f.nome.trim() || (editing ? 'Editar paciente' : 'Novo paciente')}
			</div>
			<div class="text-rotulo text-faint">
				{editing ? 'Editando ficha cadastral' : 'Cadastro de novo paciente'}{idadeVal !== null ? ` · ${idadeVal} anos` : ''}
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
						<input bind:value={f.nome} oninput={scheduleDupCheck} placeholder="Nome do paciente" class={inputCls} />
					</label>
					<label class="mb-3 block">
						{@render label('Nome social (caso aplicável)')}
						<input bind:value={f.nome_social} placeholder="Como prefere ser chamado(a)" class={inputCls} />
					</label>
					<div class="grid grid-cols-1 gap-3 md:grid-cols-2">
						<label class="block">
							{@render label('Telefone / WhatsApp', true)}
							<input value={f.tel} oninput={(e) => { f.tel = maskTel(e.currentTarget.value); scheduleDupCheck(); }} inputmode="tel" placeholder="(11) 90000-0000" class="{inputCls} font-mono" />
							<!-- Obrigatório desde a fase 2 da comunicação (doc 52 §9): é o telefone que faz o
							     paciente ser alcançável por WhatsApp. Fixo é aceito, e aí o aviso abaixo explica
							     por que a mensagem vai sair por e-mail — dizer isso aqui evita a pergunta
							     "mandei confirmação e ele não recebeu" três dias depois. -->
							{#if f.tel && !recebeWhatsapp(f.tel)}
								<span class="mt-1 block text-meta text-muted">
									Parece um fixo — este paciente receberá por e-mail, não por WhatsApp.
								</span>
							{/if}
						</label>
						<label class="block">
							{@render label('CPF')}
							<input value={f.cpf} oninput={(e) => { f.cpf = maskCpf(e.currentTarget.value); scheduleDupCheck(); }} inputmode="numeric" placeholder="000.000.000-00" class="{inputCls} font-mono" />
						</label>
					</div>
					{#if dup}
						<!-- O servidor recusa este save (identity única por clínica), então o aviso diz o
						     que fazer: se a ficha existe e está ativa, é ela que se edita; se está
						     arquivada, reativar é o caminho — recadastrar seria recusado igual. -->
						<div class="mt-3 flex items-start gap-2 rounded-controle border border-warning/30 bg-warning/10 px-3 py-2.5 text-rotulo text-ink">
							<UserSearch size={16} class="mt-0.5 shrink-0 text-warning" />
							<span>
								<b>{dup.campo} já cadastrado</b>
								{#if dup.ativo}
									na ficha de {dup.nome} — edite aquela ficha em vez de criar outra.
								{:else}
									na ficha <b>arquivada</b> de {dup.nome} — reative aquela ficha em vez de
									recadastrar.
								{/if}
							</span>
						</div>
					{/if}
					<div class="mt-3 grid grid-cols-1 gap-3 md:grid-cols-2">
						<label class="block">
							{@render label(nascLabel)}
							<!-- AN-10: nome + nascimento também consultam o duplicado (o cadastro sem documento). -->
							<input type="date" bind:value={f.nascimento} oninput={scheduleDupCheck} onchange={scheduleDupCheck} class={inputCls} />
						</label>
						<label class="block">
							{@render label('RG')}
							<input bind:value={f.rg} placeholder="Órgão emissor incl." class="{inputCls} font-mono" />
						</label>
						<label class="block">
							{@render label('Gênero')}
							<select bind:value={f.genero} class={inputCls}>
								<option value="">Selecione…</option>
								<option>Masculino</option><option>Feminino</option><option>Outro / Não informar</option>
							</select>
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
					<div class="mt-3">
						{#if needResp}
							<label class="block">
								{@render label('Responsável legal (menor de idade)')}
								<input bind:value={f.responsavel} placeholder="Nome e parentesco" class={inputCls} />
							</label>
						{:else}
							<button
								type="button"
								onclick={() => (showResp = true)}
								class="inline-flex items-center gap-1.5 rounded-controle border border-dashed border-edge px-3 py-2 text-rotulo text-muted hover:bg-surface-2"
							>
								<Plus size={14} /> Adicionar responsável legal
							</button>
						{/if}
					</div>
				</section>

				<!-- 2. Endereço & e-mail -->
				<section id="sec-contato" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(MapPin, SECTIONS[1].t, SECTIONS[1].sub, counts.contato, SECTIONS[1].total)}
					<label class="mb-3 block">
						{@render label('E-mail')}
						<!-- O e-mail também é único por clínica, então também consulta o duplicado — o aviso
						     mora na seção de identificação, que é onde a recepção está olhando. -->
						<input bind:value={f.email} oninput={scheduleDupCheck} placeholder="email@exemplo.com" class={inputCls} />
					</label>
					<div class="grid grid-cols-1 gap-3 md:grid-cols-[0.9fr_2.3fr]">
						<label class="block">
							{@render label('CEP')}
							<input value={f.cep} oninput={onCepInput} onblur={() => runCepLookup(f.cep)} inputmode="numeric" placeholder="00000-000" class="{inputCls} font-mono" />
						</label>
						<label class="block">
							{@render label('Endereço residencial')}
							<input bind:value={f.endereco} placeholder="Preenchido automaticamente pelo CEP" class={inputCls} />
						</label>
					</div>
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
					<div class="mt-3 grid grid-cols-2 gap-3 md:grid-cols-[1.5fr_1.6fr_0.5fr_0.7fr]">
						<label class="block">
							{@render label('Bairro')}
							<input bind:value={f.bairro} class={inputCls} />
						</label>
						<label class="block">
							{@render label('Cidade')}
							<input bind:value={f.cidade} class={inputCls} />
						</label>
						<label class="block">
							{@render label('UF')}
							<input value={f.uf} oninput={(e) => (f.uf = maskUf(e.currentTarget.value))} maxlength="2" placeholder="SP" class="{inputCls} uppercase" />
						</label>
						<label class="block">
							{@render label('Nº')}
							<input bind:value={f.numero} placeholder="000" class={inputCls} />
						</label>
					</div>
					<label class="mt-3 block">
						{@render label('Complemento')}
						<input bind:value={f.complemento} placeholder="Apto / bloco (opcional)" class={inputCls} />
					</label>
				</section>

				<!-- 3. Emergência -->
				<section id="sec-emergencia" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(Siren, SECTIONS[2].t, SECTIONS[2].sub, counts.emergencia, SECTIONS[2].total)}
					<div class="grid grid-cols-1 gap-3 md:grid-cols-[1.6fr_1fr_1fr]">
						<label class="block">
							{@render label('Nome do contato')}
							<input bind:value={f.emergencia_nome} class={inputCls} />
						</label>
						<label class="block">
							{@render label('Parentesco / ligação')}
							<input bind:value={f.emergencia_parentesco} placeholder="Cônjuge, mãe…" class={inputCls} />
						</label>
						<label class="block">
							{@render label('Telefone')}
							<input value={f.emergencia_tel} oninput={(e) => (f.emergencia_tel = maskTel(e.currentTarget.value))} inputmode="tel" placeholder="(11) 90000-0000" class="{inputCls} font-mono" />
						</label>
					</div>
				</section>

				<!-- 4. Dados profissionais -->
				<section id="sec-profissional" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(Briefcase, SECTIONS[3].t, SECTIONS[3].sub, counts.profissional, SECTIONS[3].total)}
					<div class="grid grid-cols-1 gap-3 md:grid-cols-2">
						<label class="block">
							{@render label('Profissão / ocupação')}
							<input bind:value={f.profissao} class={inputCls} />
						</label>
						<label class="block">
							{@render label('Empresa / instituição (opcional)')}
							<input bind:value={f.empresa} class={inputCls} />
						</label>
					</div>
				</section>

				<!-- 5. Atendimento -->
				<section id="sec-atendimento" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(CreditCard, SECTIONS[4].t, SECTIONS[4].sub, counts.atendimento, SECTIONS[4].total)}
					{@render label('Tipo de atendimento')}
					<div class="mb-1.5 flex gap-2">
						{#each [['particular', 'Particular'], ['reembolso', 'Reembolso'], ['convenio', 'Convênio']] as [val, lbl] (val)}
							<button
								type="button"
								onclick={() => (atendTipo = val)}
								class="flex-1 rounded-controle border py-2 text-rotulo font-semibold {atendTipo === val
									? 'border-transparent bg-primary text-on-primary'
									: 'border-edge bg-surface text-ink hover:bg-surface-2'}"
							>
								{lbl}
							</button>
						{/each}
					</div>
					<p class="mb-3 text-meta text-faint">
						Como esta clínica cobra o atendimento — não depende do convênio do paciente.
					</p>
					<div class="mb-3 grid grid-cols-1 gap-3 md:grid-cols-[1.7fr_1fr]">
						<label class="block">
							{@render label('Médico solicitante / encaminhador')}
							<input bind:value={f.medico} placeholder="Dr(a). Nome" class={inputCls} />
						</label>
						<label class="block">
							{@render label('CRM')}
							<input bind:value={f.crm} placeholder="CRM/SP 000000" class="{inputCls} font-mono" />
						</label>
					</div>
					<label class="block">
						{@render label('Como conheceu a nossa clínica?')}
						<select bind:value={f.como_conheceu} class={inputCls}>
							<option value="">Selecione…</option>
							<option>Indicação Médica</option><option>Indicação de Amigos</option>
							<option>Instagram</option><option>Google / Mapas</option><option>Outros</option>
						</select>
					</label>
				</section>

				<!-- 6. Convênio -->
				<section id="sec-convenio" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(BadgeCheck, SECTIONS[5].t, SECTIONS[5].sub, counts.convenio, SECTIONS[5].total)}
					<p class="mb-3 text-rotulo leading-relaxed text-muted">
						Registre o plano de saúde do paciente <b class="text-ink">mesmo em atendimento particular</b> —
						fica guardado caso seja preciso encaminhar para outro tratamento coberto pelo convênio.
					</p>
					<label class="flex items-center gap-2.5 rounded-controle border border-edge bg-surface-2 px-3 py-2.5 text-corpo">
						<input type="checkbox" bind:checked={temConvenio} class="size-4 accent-primary" />
						<span class="font-semibold">O paciente possui convênio / plano de saúde</span>
					</label>
					{#if temConvenio}
						<div class="mt-3.5 grid grid-cols-1 gap-3 md:grid-cols-[1.6fr_1.2fr_0.9fr]">
							<label class="block">
								{@render label('Nome do convênio')}
								<input bind:value={f.convenio} placeholder="Nome do plano" class={inputCls} />
							</label>
							<label class="block">
								{@render label('Nº da carteirinha')}
								<input bind:value={f.carteirinha} class="{inputCls} font-mono" />
							</label>
							<label class="block">
								{@render label('Validade')}
								<input value={f.convenio_validade} oninput={(e) => (f.convenio_validade = maskMy(e.currentTarget.value))} inputmode="numeric" placeholder="MM/AAAA" class="{inputCls} font-mono" />
							</label>
						</div>
					{/if}
				</section>

				<!-- 7. Preferências clínicas -->
				<section id="sec-clinico" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(Stethoscope, SECTIONS[6].t, SECTIONS[6].sub, counts.clinico, SECTIONS[6].total)}
					{@render label('Profissional preferido — pode escolher mais de um')}
					{#if activeProfs.length}
						<div class="mb-4 flex flex-wrap gap-2">
							{#each activeProfs as p (p.id)}
								{@const on = prefs.includes(p.id)}
								<button
									type="button"
									onclick={() => togglePref(p.id)}
									class="flex items-center gap-1.5 rounded-full border py-1.5 pl-1.5 pr-2.5 text-rotulo font-semibold {on
										? 'border-transparent bg-accent-subtle text-accent-text'
										: 'border-edge bg-surface text-ink hover:bg-surface-2'}"
								>
									<span class="grid size-5 place-items-center rounded-full text-micro font-bold" style={avatarStyle(p.cor_indice)}>
										{initials(p.nome)}
									</span>
									{stripTitle(p.nome)}{#if on}<Check size={13} />{/if}
								</button>
							{/each}
						</div>
					{:else}
						<p class="mb-4 text-rotulo text-faint">Nenhum profissional cadastrado ainda.</p>
					{/if}

					{@render label('Tags / condições clínicas')}
					<div class="flex min-h-[38px] flex-wrap items-center gap-1.5 rounded-controle border border-edge bg-surface p-1.5">
						{#each tags as t (t)}
							<span class="inline-flex items-center gap-1.5 rounded-controle bg-accent-subtle py-0.5 pl-2 pr-1 text-rotulo font-semibold text-accent-text">
								{t}
								<button type="button" onclick={() => removeTag(t)} aria-label="Remover {t}" class="grid size-4 place-items-center rounded-micro text-accent-text hover:bg-accent/20">
									<X size={12} />
								</button>
							</span>
						{/each}
						<input
							bind:value={tagInput}
							onkeydown={onTagKey}
							onblur={() => addTag(tagInput)}
							placeholder={tags.length ? '' : 'Digite e tecle Enter'}
							aria-label="Adicionar tag"
							class="h-[26px] min-w-[130px] flex-1 border-none bg-transparent text-corpo text-ink outline-none"
						/>
					</div>
					<div class="mt-2 flex flex-wrap gap-1.5">
						{#each SUGG.filter((s) => !tags.includes(s)).slice(0, 8) as s (s)}
							<button type="button" onclick={() => addTag(s)} class="rounded-full border border-dashed border-edge px-2 py-0.5 text-meta text-muted hover:bg-surface-2">
								+ {s}
							</button>
						{/each}
					</div>
				</section>

				<!-- 8. Consentimento -->
				<section id="sec-consentimento" class="scroll-mt-4 rounded-cartao border border-edge bg-surface p-5">
					{@render cardHead(ShieldCheck, SECTIONS[7].t, SECTIONS[7].sub, counts.consentimento, SECTIONS[7].total)}
					<label class="flex items-start gap-2.5 rounded-controle border border-edge bg-surface-2 px-3 py-2.5 text-rotulo">
						<input type="checkbox" bind:checked={lgpd} class="mt-0.5 size-4 accent-primary" />
						<span class="text-muted">
							Autorizo o tratamento dos meus dados pessoais e dados sensíveis de saúde para compor o
							prontuário, emitir documentos e planejar a assistência, conforme a
							<b class="text-ink">LGPD (Lei nº 13.709/2018)</b>.
						</span>
					</label>
					<label class="mt-2.5 flex items-start gap-2.5 rounded-controle border border-edge bg-surface-2 px-3 py-2.5 text-rotulo">
						<input type="checkbox" bind:checked={comunicacao} class="mt-0.5 size-4 accent-primary" />
						<!-- O texto mudou junto com o default (doc 52 §11.2): a caixa deixou de ser
						     "autorizar" e passou a ser algo que se DESMARCA, então ela precisa dizer o que
						     sai por ali. Desmarcar sem saber o que se está desligando é adivinhação.
						     A menção ao WhatsApp fica: é o canal que o paciente reconhece, e é para onde a
						     fase 2 vai. -->
						<span class="text-muted">
							Receber <b class="text-ink">confirmação e lembrete das sessões</b> por e-mail ou
							WhatsApp. Desmarque se o paciente pediu para não ser contatado.
						</span>
					</label>
				</section>
			</div>
		</div>
	</div>

	<!-- Rodapé fixo -->
	<footer class="flex shrink-0 items-center gap-3 border-t border-edge bg-surface px-4 py-3 md:px-6">
		<!--
			ACC-04 (doc 83): problema e DICA são coisas diferentes, e antes dividiam o mesmo `<span
			class="hidden … md:flex">`. Consequências, as duas medidas: no celular o 422 do servidor
			não aparecia em lugar nenhum (o espaço dele era um `<div>` vazio), e em nenhuma largura
			havia live region, então o leitor de tela nunca recebia o erro.

			Agora: **problema** é `role="alert"` e visível em qualquer largura; **dica** continua só no
			desktop (esconder uma dica não custa tarefa) e sem `role`, senão o leitor a anunciaria a
			cada tecla digitada.
		-->
		{#if problema}
			<span role="alert" class="flex flex-1 items-center gap-1.5 text-rotulo text-danger">
				<TriangleAlert size={14} class="shrink-0" /> {problema}
			</span>
		{:else}
			<!-- Era "nenhum campo é obrigatório", e a frase sobreviveu à `TelObrigatorio`: o
			     asterisco já estava no rótulo do telefone e o rodapé seguia prometendo o
			     contrário, na mesma tela. -->
			<span class="hidden flex-1 items-center gap-1.5 text-rotulo text-faint md:flex">
				Nome e telefone são obrigatórios — o resto pode ficar para depois.
			</span>
			<div class="flex-1 md:hidden"></div>
		{/if}
		<a
			href={editing ? `/pacientes/${patient?.id}` : '/pacientes'}
			class="rounded-controle border border-edge bg-surface px-4 py-2 text-corpo font-semibold text-ink hover:bg-surface-2"
			>Cancelar</a
		>
		<Button type="submit"
			emVoo={submitting}
			disabled={!nomeOk || !telOk || !identOk}
		>
			{editing ? 'Salvar' : 'Cadastrar paciente'}
		</Button>
	</footer>
</form>
