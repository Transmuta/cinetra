<script lang="ts">
	// Landing pública Cinetra (interface/Cinetra Landing.dc.html). Paleta quente escopada em
	// .cn-root (cinetra.css); a arte orgânica é FlowArt; CTAs levam a /criar-conta e /entrar.
	import Logo from '$lib/components/Logo.svelte';
	import Mark from '$lib/components/Mark.svelte';
	import FlowArt from '$lib/components/cinetra/FlowArt.svelte';
	import { SITE, FAQ, jsonLd } from '$lib/seo';
	import '$lib/styles/cinetra.css';

	// `canonical` e `origem` vêm do servidor (+page.server.ts): dependem do `ORIGIN`, que o
	// cliente não conhece.
	let { data }: { data: { canonical: string; origem: string } } = $props();

	// Toggle de cobrança do bloco de planos (mensal/anual), como no protótipo.
	let billing = $state<'mensal' | 'anual'>('anual');
	const anual = $derived(billing === 'anual');
	const precoPro = $derived(anual ? '149' : '189');
	const precoClinica = $derived(anual ? '289' : '349');
	const periodo = $derived(anual ? '/mês · cobrado anualmente' : '/mês');

	const dores = [
		{
			n: '01',
			title: 'A agenda vive em três lugares',
			desc: 'Caderno, planilha e memória. Basta um encaixe errado para o dia inteiro travar.',
			solution: 'Uma agenda única e sempre atualizada, que evita conflitos sozinha.',
			bullets: [
				'Todas as agendas da equipe em uma tela',
				'Bloqueio automático de horários duplicados',
				'Reagendar arrastando, sem retrabalho'
			]
		},
		{
			n: '02',
			title: 'Cada falta é um buraco no caixa',
			desc: 'O paciente esquece, ninguém confirma e o horário fica vazio sem aviso.',
			solution: 'Confirmação automática no WhatsApp que preenche a agenda de novo.',
			bullets: [
				'Lembrete enviado 24h e 2h antes da sessão',
				'Paciente confirma ou remarca com um toque',
				'Horário vago liberado na hora para a fila de espera'
			]
		},
		{
			n: '03',
			title: 'O pacote acaba e você nem viu',
			desc: 'Sessões perdidas, renovação atrasada e receita que escorre sem ninguém notar.',
			solution: 'Pacotes com trilha visual e alerta de renovação em um clique.',
			bullets: [
				'Contador de sessões usadas e restantes por paciente',
				'Aviso automático quando o pacote está acabando',
				'Renovação registrada sem refazer o cadastro'
			]
		}
	];

	const agendaChecks = [
		'Detecção automática de conflitos',
		'Visão por dia, semana ou profissional',
		'Bloqueios, folgas e exceções por data'
	];

	const proFeatures = [
		'1 profissional',
		'Agenda e pacotes',
		'Confirmação no WhatsApp',
		// "Prontuário" era promessa de v2 (doc 08, Fatia 6): o que a v1 entrega — e o que a tela
		// mostra — é a ficha. Corrigido junto com o FAQ, que responde sobre a mesma coisa.
		'Ficha do paciente'
	];
	const clinicaFeatures = [
		'Até 8 profissionais',
		'Tudo do Profissional',
		'Painel da recepção',
		'Relatórios de ocupação'
	];
	const redeFeatures = [
		'Unidades ilimitadas',
		'SSO e permissões',
		'Suporte dedicado',
		'Onboarding assistido'
	];

	// Trilha de 10 sessões: 9 marcadores + 1 alvo vazio; o índice 3 é a falta (âmbar).
	const trilha = [...Array(9).keys()];

	const tabOn =
		'font-size:14px;font-weight:700;padding:8px 18px;border-radius:9px;border:none;cursor:pointer;background:#fff;color:#212A37;box-shadow:0 2px 6px rgba(33,42,55,.12)';
	const tabOff =
		'font-size:14px;font-weight:600;padding:8px 18px;border-radius:9px;border:none;cursor:pointer;background:transparent;color:#5E594C';
</script>

<svelte:head>
	<title>{SITE.titulo}</title>
	<meta name="description" content={SITE.descricao} />

	<!-- Canônica: a landing é alcançável por `/` com toda sorte de `?utm_…` de campanha, e sem
	     esta linha cada campanha vira uma URL concorrente da mesma página no índice. -->
	<link rel="canonical" href={data.canonical} />

	<!-- Cor da barra do browser no celular — o navy da marca, para a landing não abrir com uma
	     faixa branca em cima do herói escuro. -->
	<meta name="theme-color" content="#212A37" />

	<!-- Open Graph (WhatsApp, Facebook, LinkedIn). O título aqui é a MANCHETE, não o título de
	     busca: quem vê um card já veio pelo link, não por uma consulta — vende-se a promessa,
	     não a palavra-chave. A imagem é gerada por `scripts/og-image.mjs`. -->
	<meta property="og:type" content="website" />
	<meta property="og:site_name" content={SITE.nome} />
	<meta property="og:locale" content={SITE.locale} />
	<meta property="og:url" content={data.canonical} />
	<meta property="og:title" content={SITE.manchete} />
	<meta property="og:description" content={SITE.descricao} />
	<meta property="og:image" content={`${data.origem}/og.png`} />
	<meta property="og:image:width" content="1200" />
	<meta property="og:image:height" content="630" />
	<meta property="og:image:alt" content="Cinetra: agenda e gestão para clínicas de fisioterapia" />

	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content={SITE.manchete} />
	<meta name="twitter:description" content={SITE.descricao} />
	<meta name="twitter:image" content={`${data.origem}/og.png`} />

	<!-- Dados estruturados (schema.org). Sem `aggregateRating`: ver a justificativa em
	     `$lib/seo.ts` — declarar nota agregada sem review verificável é spam estrutural. -->
	{@html `<script type="application/ld+json">${JSON.stringify(jsonLd(data.origem)).replace(
		/</g,
		'\\u003c'
	)}<\/script>`}
</svelte:head>

{#snippet check(stroke: string, size: number)}
	<svg
		width={size}
		height={size}
		viewBox="0 0 24 24"
		fill="none"
		stroke={stroke}
		stroke-width="2.4"
		style="flex-shrink:0"><path d="m20 6-11 11-5-5" stroke-linecap="round" stroke-linejoin="round" /></svg
	>
{/snippet}

<div class="cn-root cn-landing" style="min-height:100dvh">
	<!-- Atalho de teclado: a nav é curta, mas o herói tem arte e dois CTAs antes do conteúdo.
	     Só aparece ao receber foco (`.cn-skip`, cinetra.css). -->
	<a href="#conteudo" class="cn-skip">Pular para o conteúdo</a>

	<!-- NAV -->
	<header
		style="position:sticky;top:0;z-index:60;background:#F6F4EF;border-bottom:1px solid #E6E2D8"
	>
		<div
			class="cn-topbar"
			style="max-width:1160px;margin:0 auto;padding:13px 30px;display:flex;align-items:center;gap:34px"
		>
			<a href="/" aria-label="Cinetra, página inicial" style="display:flex;align-items:center"
				><Logo class="h-5.75 w-auto" /></a
			>
			<nav
				class="cn-navlinks"
				aria-label="Seções da página"
				style="display:flex;gap:26px;margin-left:8px;font-size:14.5px;font-weight:500;color:#5A5448"
			>
				<a href="#dores" style="transition:color .2s">As dores</a>
				<a href="#recursos" style="transition:color .2s">Recursos</a>
				<a href="#precos" style="transition:color .2s">Planos</a>
				<a href="#duvidas" style="transition:color .2s">Dúvidas</a>
			</nav>
			<div style="margin-left:auto;display:flex;align-items:center;gap:6px">
				<a
					href="/entrar"
					class="cn-hover-nav"
					style="color:#212A37;font-size:14.5px;font-weight:600;padding:8px 14px;border-radius:9px">Entrar</a
				>
				<a
					href="/criar-conta"
					class="cn-hover-dark"
					style="background:#212A37;color:#fff;font-size:14.5px;font-weight:600;padding:9px 16px;border-radius:9px"
					>Começar grátis</a
				>
			</div>
		</div>
	</header>

	<!-- A página não tinha landmark nenhum: todo o conteúdo era filho direto de uma `div`. As
	     seções abaixo NÃO foram reindentadas de propósito — recuar 630 linhas por um wrapper
	     esconderia o resto da mudança no diff. -->
	<main id="conteudo">
	<!-- HERO -->
	<section style="position:relative;overflow:hidden;background:#212A37">
		<div style="position:absolute;inset:0"><FlowArt k="hero" /></div>
		<div
			style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(33,42,55,.55) 0%,rgba(33,42,55,.18) 38%,rgba(33,42,55,.35) 100%);pointer-events:none"
		></div>
		<div
			class="cn-sect"
			style="position:relative;max-width:1160px;margin:0 auto;padding:130px 30px 120px"
		>
			<div class="cn-hero-in" style="max-width:840px;animation:cnRise .9s ease both">
				<h1
					class="cn-h1"
					style="font-size:80px;line-height:1.02;letter-spacing:-.035em;font-weight:800;color:#fff;margin:0;text-wrap:balance;text-shadow:0 4px 34px rgba(0,0,0,.28)"
				>
					Sua clínica respira quando a agenda cuida de si mesma.
				</h1>
				<p
					style="font-size:21px;line-height:1.5;color:#E3E9E6;margin:28px 0 0;max-width:580px;text-wrap:pretty"
				>
					Horários, pacotes e confirmações num lugar só. A Cinetra cuida da papelada para você cuidar
					de quem chega.
				</p>
				<div style="display:flex;flex-wrap:wrap;gap:14px;margin-top:38px">
					<a
						href="/criar-conta"
						class="cn-hover-white"
						style="display:inline-flex;align-items:center;gap:10px;background:#fff;color:#212A37;font-size:17px;font-weight:700;padding:16px 28px;border-radius:14px"
						>Começar 14 dias grátis
						<svg
							width="19"
							height="19"
							viewBox="0 0 24 24"
							fill="none"
							stroke="currentColor"
							stroke-width="2"
							stroke-linecap="round"
							stroke-linejoin="round"
							><line x1="5" y1="12" x2="19" y2="12"></line><polyline points="12 5 19 12 12 19"
							></polyline></svg
						></a
					>
					<a
						href="/entrar"
						class="cn-hover-glass"
						style="display:inline-flex;align-items:center;background:rgba(255,255,255,.1);border:1px solid rgba(255,255,255,.4);color:#fff;font-size:17px;font-weight:600;padding:16px 26px;border-radius:14px;backdrop-filter:blur(6px)"
						>Ver a plataforma</a
					>
				</div>
				<div
					style="display:flex;align-items:center;gap:8px;margin-top:24px;font-size:14px;color:#B7C0C8"
				>
					<svg
						width="16"
						height="16"
						viewBox="0 0 24 24"
						fill="none"
						stroke="#7FA59A"
						stroke-width="2.6"
						stroke-linecap="round"
						stroke-linejoin="round"><polyline points="20 6 9 17 4 12"></polyline></svg
					>
					Sem cartão de crédito · configure em minutos
				</div>
			</div>
		</div>
		<div
			style="position:absolute;left:50%;bottom:26px;transform:translateX(-50%);color:#fff;animation:cnScrollcue 2s ease-in-out infinite;pointer-events:none"
		>
			<svg
				width="26"
				height="26"
				viewBox="0 0 24 24"
				fill="none"
				stroke="currentColor"
				stroke-width="2"
				stroke-linecap="round"
				stroke-linejoin="round"><path d="M12 5v14"></path><path d="m19 12-7 7-7-7"></path></svg
			>
		</div>
	</section>

	<!-- AS DORES -->
	<section
		id="dores"
		class="cn-sect"
		style="position:relative;padding:120px 0 110px;overflow:hidden"
	>
		<div
			style="position:absolute;top:-90px;right:-70px;width:380px;height:380px;background:radial-gradient(circle at 40% 40%,rgba(127,165,154,.42),rgba(127,165,154,0) 70%);animation:cnBlob 16s ease-in-out infinite;pointer-events:none"
		></div>
		<div class="cn-wrap" style="position:relative;max-width:1160px;margin:0 auto;padding:0 30px">
			<div style="max-width:780px">
				<div
					style="font-family:'Martian Mono',monospace;font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:#4A6E62;margin-bottom:22px"
				>
					Talvez soe familiar
				</div>
				<h2
					style="font-size:52px;line-height:1.08;letter-spacing:-.03em;font-weight:800;margin:0;text-wrap:balance"
				>
					A rotina da clínica não deveria doer mais que o paciente.
				</h2>
				<p
					style="font-size:19px;line-height:1.55;color:#696356;margin:22px 0 0;max-width:560px;text-wrap:pretty"
				>
					Três problemas que roubam tempo e dinheiro todo dia. Veja como a Cinetra resolve cada um.
				</p>
			</div>
			<div style="margin-top:60px">
				{#each dores as dor, i (dor.n)}
					<div
						class="cn-dorow"
						style="display:grid;grid-template-columns:64px 1fr 1fr;gap:36px;align-items:start;padding:34px 0;border-top:1px solid #DCD8CE;{i ===
						dores.length - 1
							? 'border-bottom:1px solid #DCD8CE'
							: ''}"
					>
						<div style="font-family:'Martian Mono',monospace;font-size:15px;color:#696356">{dor.n}</div>
						<div>
							<!-- `h3` e não `div`: são as três subseções do `h2` desta seção. Como div, o índice
							     do buscador (e o leitor de tela) via um bloco de 52px seguido de texto solto,
							     sem saber que ali começa um assunto novo. -->
							<h3 style="font-size:26px;font-weight:700;line-height:1.25;letter-spacing:-.01em;margin:0">
								{dor.title}
							</h3>
							<p style="font-size:16px;color:#696356;margin:10px 0 0;line-height:1.55">{dor.desc}</p>
						</div>
						<div style="display:flex;gap:12px;align-items:flex-start">
							<span style="margin-top:2px">{@render check('#7FA59A', 22)}</span>
							<div>
								<div style="font-size:16px;color:#3B463B;font-weight:600;line-height:1.5">
									{dor.solution}
								</div>
								<div style="display:flex;flex-direction:column;gap:6px;margin-top:12px">
									{#each dor.bullets as b (b)}
										<div style="display:flex;gap:8px;align-items:center;font-size:14px;color:#6B665A">
											<span
												style="width:5px;height:5px;border-radius:50%;background:#7FA59A;flex-shrink:0"
											></span>{b}
										</div>
									{/each}
								</div>
							</div>
						</div>
					</div>
				{/each}
			</div>
		</div>
	</section>

	<!-- RECURSO 1 · Agenda -->
	<section
		id="recursos"
		class="cn-sect"
		style="position:relative;background:#212A37;color:#EAF0EE;padding:110px 0;overflow:hidden"
	>
		<div
			style="position:absolute;bottom:-130px;left:-90px;width:440px;height:440px;background:radial-gradient(circle at 50% 50%,rgba(58,90,120,.55),transparent 70%);animation:cnBlob 18s ease-in-out infinite;pointer-events:none"
		></div>
		<div
			class="cn-grid2 cn-wrap"
			style="position:relative;max-width:1160px;margin:0 auto;padding:0 30px;display:grid;grid-template-columns:1fr 1.05fr;gap:64px;align-items:center"
		>
			<div>
				<div
					style="font-family:'Martian Mono',monospace;font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:#7FA59A;margin-bottom:20px"
				>
					Recurso · Agenda
				</div>
				<h2
					style="font-size:46px;line-height:1.1;letter-spacing:-.03em;font-weight:800;color:#fff;margin:0;text-wrap:balance"
				>
					Enxergue a semana inteira num só olhar.
				</h2>
				<p style="font-size:18px;line-height:1.6;color:#B7C0C8;margin:22px 0 30px;max-width:460px">
					Arraste para reagendar, encaixe sem conflito e dê a cada profissional a sua cor. A recepção
					para de adivinhar e a agenda flui.
				</p>
				<div style="display:flex;flex-direction:column;gap:14px">
					{#each agendaChecks as c (c)}
						<div style="display:flex;gap:11px;align-items:center;font-size:16px;color:#DCE3E0">
							{@render check('#7FA59A', 19)}{c}
						</div>
					{/each}
				</div>
			</div>
			<div style="animation:cnFloat 7s ease-in-out infinite">
				<div
					style="background:#fff;border-radius:20px;box-shadow:0 40px 80px -40px rgba(0,0,0,.6);padding:20px;color:#212A37"
				>
					<div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:16px">
						<div>
							<div
								style="font-size:12px;font-family:'Martian Mono',monospace;color:#697077;text-transform:uppercase"
							>
								Terça · 14 jul
							</div>
							<div style="font-size:18px;font-weight:700;margin-top:2px">Agenda da clínica</div>
						</div>
						<div style="display:flex">
							<span
								style="width:29px;height:29px;border-radius:50%;background:#3A5A78;color:#fff;display:grid;place-items:center;font-size:11px;font-weight:700;border:2px solid #fff"
								>ML</span
							><span
								style="width:29px;height:29px;border-radius:50%;background:#4A6E62;color:#fff;display:grid;place-items:center;font-size:11px;font-weight:700;border:2px solid #fff;margin-left:-8px"
								>RC</span
							>
						</div>
					</div>
					<div style="display:flex;flex-direction:column;gap:8px">
						<div
							style="display:flex;gap:11px;align-items:center;padding:11px 12px;border-radius:12px;background:#F1F6F4"
						>
							<div style="font-family:'Martian Mono',monospace;font-size:11px;color:#4A6E62;width:40px">
								08:00
							</div>
							<div style="flex:1">
								<div style="font-size:13px;font-weight:700">Mariana Alves</div>
								<div style="font-size:11px;color:#697077">Sessão · Dra. Marina</div>
							</div>
							<span
								style="font-size:10px;font-weight:700;color:#3E5C52;background:rgba(127,165,154,.2);padding:3px 7px;border-radius:6px"
								>9/10</span
							>
						</div>
						<div
							style="display:flex;gap:11px;align-items:center;padding:11px 12px;border-radius:12px;background:#EEF3F7"
						>
							<div style="font-family:'Martian Mono',monospace;font-size:11px;color:#3A5A78;width:40px">
								09:00
							</div>
							<div style="flex:1">
								<div style="font-size:13px;font-weight:700">Carlos Eduardo</div>
								<div style="font-size:11px;color:#697077">Avaliação · Dr. Rafael</div>
							</div>
						</div>
						<div
							style="display:flex;gap:11px;align-items:center;padding:11px 12px;border-radius:12px;background:#fff;border:1px dashed #D5DCDE"
						>
							<div style="font-family:'Martian Mono',monospace;font-size:11px;color:#697077;width:40px">
								10:00
							</div>
							<div style="flex:1;font-size:12px;color:#697077">Horário livre</div>
						</div>
						<div
							style="display:flex;gap:11px;align-items:center;padding:11px 12px;border-radius:12px;background:#F1F6F4"
						>
							<div style="font-family:'Martian Mono',monospace;font-size:11px;color:#4A6E62;width:40px">
								11:00
							</div>
							<div style="flex:1">
								<div style="font-size:13px;font-weight:700">Turma de Pilates</div>
								<div style="font-size:11px;color:#697077">4 pacientes · Dra. Carla</div>
							</div>
						</div>
					</div>
				</div>
			</div>
		</div>
	</section>

	<!-- RECURSO 2 · Pacotes -->
	<section class="cn-sect" style="padding:110px 0;background:#F6F4EF">
		<div
			class="cn-grid2 cn-wrap"
			style="max-width:1160px;margin:0 auto;padding:0 30px;display:grid;grid-template-columns:1.05fr 1fr;gap:64px;align-items:center"
		>
			<div style="order:2">
				<div
					style="font-family:'Martian Mono',monospace;font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:#4A6E62;margin-bottom:20px"
				>
					Recurso · Pacotes
				</div>
				<h2
					style="font-size:46px;line-height:1.1;letter-spacing:-.03em;font-weight:800;margin:0;text-wrap:balance"
				>
					Acompanhe cada sessão como uma trilha.
				</h2>
				<p style="font-size:18px;line-height:1.6;color:#696356;margin:22px 0 30px;max-width:460px">
					Monte o pacote, distribua a grade fixa da semana e enxergue de longe quando ele está
					acabando. O aviso de renovação chega antes de você perder a próxima sessão.
				</p>
				<div style="display:flex;gap:32px">
					<div>
						<div style="font-size:34px;font-weight:800;letter-spacing:-.02em">1 clique</div>
						<div style="font-size:14px;color:#696356">para renovar o pacote</div>
					</div>
					<div>
						<div style="font-size:34px;font-weight:800;color:#4A6E62;letter-spacing:-.02em">zero</div>
						<div style="font-size:14px;color:#696356">sessões esquecidas</div>
					</div>
				</div>
			</div>
			<div
				style="order:1;background:#fff;border:1px solid #E6E2D8;border-radius:20px;padding:28px;box-shadow:0 30px 60px -40px rgba(33,42,55,.35)"
			>
				<div style="display:flex;align-items:center;gap:10px;margin-bottom:20px">
					<span
						style="font-family:'Martian Mono',monospace;font-size:11px;font-weight:700;color:#3A5A78;background:rgba(58,90,120,.1);padding:3px 9px;border-radius:6px"
						>FISIO ORTOPÉDICA</span
					><span style="font-size:13px;color:#697077">10 sessões</span>
				</div>
				<div style="font-size:15px;font-weight:700;margin-bottom:16px">
					Mariana Alves · 9 de 10 concluídas
				</div>
				<div style="display:flex;gap:9px;align-items:center;margin-bottom:20px;flex-wrap:wrap">
					{#each trilha as i (i)}
						{#if i === 3}
							<span
								style="width:22px;height:22px;border-radius:50%;background:#E5B94E;display:grid;place-items:center;font-size:11px;color:#4A3B0C;font-weight:700"
								>!</span
							>
						{:else}
							<span
								style="width:22px;height:22px;border-radius:50%;background:#7FA59A;display:grid;place-items:center"
								>{@render check('#fff', 12)}</span
							>
						{/if}
					{/each}
					<span
						style="width:22px;height:22px;border-radius:50%;background:#fff;border:2px solid #7FA59A;box-shadow:0 0 0 3px rgba(127,165,154,.25)"
					></span>
				</div>
				<div
					style="display:flex;align-items:center;justify-content:space-between;padding:13px 15px;border-radius:12px;background:#FBF6EA;border:1px solid #F0E4C6"
				>
					<div style="display:flex;gap:10px;align-items:center">
						<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#8A6A14" stroke-width="2"
							><circle cx="12" cy="12" r="10"></circle><path
								d="M12 8v4l3 2"
								stroke-linecap="round"
								stroke-linejoin="round"
							></path></svg
						>
						<div style="font-size:13px;font-weight:600;color:#8A6A14">Pacote acabando · renove agora</div>
					</div>
					<span
						style="font-size:12px;font-weight:700;color:#fff;background:#212A37;padding:6px 12px;border-radius:8px"
						>Renovar</span
					>
				</div>
			</div>
		</div>
	</section>

	<!-- RECURSO 3 · Confirmação -->
	<section style="position:relative;overflow:hidden;background:#4E7468">
		<div style="position:absolute;inset:0"><FlowArt k="conf" bg="#3C5C52" c1="#5E8578" c2="#B7D3C9" /></div>
		<div
			style="position:absolute;inset:0;background:linear-gradient(90deg,rgba(20,32,27,.9) 0%,rgba(20,32,27,.55) 52%,rgba(20,32,27,.15) 100%);pointer-events:none"
		></div>
		<div class="cn-sect" style="position:relative;max-width:1160px;margin:0 auto;padding:120px 30px">
			<div style="max-width:560px">
				<div
					style="font-family:'Martian Mono',monospace;font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:#B7D3C9;margin-bottom:20px"
				>
					Recurso · Confirmações
				</div>
				<h2
					style="font-size:46px;line-height:1.1;letter-spacing:-.03em;font-weight:800;color:#fff;margin:0;text-wrap:balance"
				>
					O WhatsApp confirma. Você respira.
				</h2>
				<p style="font-size:18px;line-height:1.6;color:#E3EDE9;margin:22px 0 0">
					Lembrete no dia certo, confirmação com um toque e remarcação sem ligação nenhuma. A recepção
					deixa de perseguir paciente e volta a acolher.
				</p>
				<div
					style="display:inline-flex;align-items:center;gap:11px;margin-top:28px;background:#fff;border-radius:14px;padding:13px 17px;box-shadow:0 20px 40px -20px rgba(0,0,0,.5)"
				>
					<span
						style="width:36px;height:36px;border-radius:9px;background:rgba(127,165,154,.16);color:#4A6E62;display:grid;place-items:center"
						><svg
							width="19"
							height="19"
							viewBox="0 0 24 24"
							fill="none"
							stroke="currentColor"
							stroke-width="2"
							stroke-linecap="round"
							stroke-linejoin="round"
							><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path></svg
						></span
					>
					<div style="color:#212A37">
						<div style="font-size:13px;font-weight:700">"Confirmo minha sessão 👍"</div>
						<div style="font-size:11px;color:#697077">Mariana · há 2 min</div>
					</div>
				</div>
			</div>
		</div>
	</section>

	<!-- NÚMEROS -->
	<section class="cn-sect" style="background:#7FA59A;padding:96px 0;color:#16241E">
		<div
			class="cn-num cn-wrap"
			style="max-width:1160px;margin:0 auto;padding:0 30px;display:grid;grid-template-columns:repeat(3,1fr);gap:40px;text-align:center"
		>
			<div>
				<div style="font-size:64px;font-weight:800;letter-spacing:-.03em">−40%</div>
				<div style="font-size:16px;color:#1E332C;margin-top:6px">de faltas já no primeiro mês</div>
			</div>
			<div
				style="border-left:1px solid rgba(22,36,30,.18);border-right:1px solid rgba(22,36,30,.18)"
			>
				<div style="font-size:64px;font-weight:800;letter-spacing:-.03em">+12h</div>
				<div style="font-size:16px;color:#1E332C;margin-top:6px">economizadas por semana</div>
			</div>
			<div>
				<div style="font-size:64px;font-weight:800;letter-spacing:-.03em">4,9/5</div>
				<div style="font-size:16px;color:#1E332C;margin-top:6px">avaliação das clínicas</div>
			</div>
		</div>
	</section>

	<!-- DEPOIMENTO -->
	<section class="cn-sect" style="padding:110px 0;background:#F6F4EF">
		<div
			class="cn-depo cn-wrap"
			style="max-width:1160px;margin:0 auto;padding:0 30px;display:grid;grid-template-columns:340px 1fr;gap:56px;align-items:center"
		>
			<div
				style="position:relative;height:360px;border-radius:22px;overflow:hidden;box-shadow:0 30px 60px -40px rgba(33,42,55,.5);background:#212A37"
			>
				<FlowArt k="port" />
			</div>
			<div>
				<div
					class="cn-quote"
					style="font-size:34px;line-height:1.35;font-weight:700;letter-spacing:-.015em;text-wrap:balance"
				>
					"A recepção parou de viver na planilha e as faltas despencaram. A Cinetra devolveu o tempo
					que a gente gastava correndo atrás de paciente."
				</div>
				<div style="display:flex;align-items:center;gap:13px;margin-top:28px">
					<span
						style="width:46px;height:46px;border-radius:50%;background:#3A5A78;color:#fff;display:grid;place-items:center;font-weight:700"
						>ML</span
					>
					<div>
						<div style="font-weight:700">Dra. Marina Lopes</div>
						<div style="font-size:14px;color:#696356">Clínica Reabilitar · São Paulo</div>
					</div>
				</div>
			</div>
		</div>
	</section>

	<!-- PLANOS -->
	<section id="precos" class="cn-sect" style="padding:110px 0;background:#F0EEE7">
		<div class="cn-wrap" style="max-width:1160px;margin:0 auto;padding:0 30px">
			<div style="text-align:center;max-width:600px;margin:0 auto 20px">
				<div
					style="font-family:'Martian Mono',monospace;font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:#4A6E62;margin-bottom:16px"
				>
					Planos
				</div>
				<h2
					style="font-size:44px;line-height:1.1;letter-spacing:-.03em;font-weight:800;margin:0 0 12px;text-wrap:balance"
				>
					Cresça no seu ritmo.
				</h2>
				<p style="font-size:17px;color:#696356;margin:0">
					14 dias grátis em qualquer plano. Cancele quando quiser.
				</p>
			</div>
			<!-- Os dois botões são um par de escolha exclusiva, não dois comandos independentes: sem
			     `group` + `aria-pressed` o leitor de tela anuncia "Mensal, botão / Anual, botão" e
			     não diz qual está valendo — a única pista era a cor do fundo. -->
			<div style="display:flex;justify-content:center;margin:26px 0 40px">
				<div
					role="group"
					aria-label="Periodicidade da cobrança"
					style="display:inline-flex;background:#E2DFD5;border-radius:12px;padding:4px;gap:2px"
				>
					<button
						onclick={() => (billing = 'mensal')}
						aria-pressed={!anual}
						style={anual ? tabOff : tabOn}>Mensal</button
					>
					<button onclick={() => (billing = 'anual')} aria-pressed={anual} style={anual ? tabOn : tabOff}
						>Anual&nbsp;<span style="font-size:11px;color:#4A6E62;font-weight:700">−20%</span></button
					>
				</div>
			</div>
			<div
				class="cn-grid3"
				style="display:grid;grid-template-columns:repeat(3,1fr);gap:20px;align-items:start"
			>
				<!-- Profissional -->
				<div style="background:#fff;border:1px solid #E6E2D8;border-radius:20px;padding:30px">
					<!-- `h3`: o nome do plano é o título do card, subordinado ao `h2` "Cresça no seu ritmo". -->
					<h3
						style="font-size:14px;font-weight:700;font-family:'Martian Mono',monospace;letter-spacing:.04em;color:#5C6670;text-transform:uppercase;margin:0"
					>
						Profissional
					</h3>
					<div style="font-size:14px;color:#696356;margin:8px 0 20px">
						Para autônomos e consultórios individuais.
					</div>
					<div style="font-size:40px;font-weight:800;letter-spacing:-.02em">R$&nbsp;{precoPro}</div>
					<div style="font-size:13px;color:#696356;margin:4px 0 22px">{periodo}</div>
					<a
						href="/criar-conta"
						class="cn-hover-border"
						style="display:block;text-align:center;box-sizing:border-box;width:100%;background:#fff;border:1px solid #D9D4C7;color:#212A37;font-size:15px;font-weight:600;padding:12px;border-radius:11px;margin-bottom:22px"
						>Começar grátis</a
					>
					<div style="display:flex;flex-direction:column;gap:11px;font-size:14px;color:#3D454F">
						{#each proFeatures as f (f)}
							<div style="display:flex;gap:9px">{@render check('#7FA59A', 18)}{f}</div>
						{/each}
					</div>
				</div>
				<!-- Clínica (popular) -->
				<div
					style="background:#212A37;border:1px solid #212A37;border-radius:20px;padding:30px;position:relative;box-shadow:0 30px 60px -30px rgba(33,42,55,.5)"
				>
					<span
						style="position:absolute;top:20px;right:20px;font-size:11px;font-weight:700;font-family:'Martian Mono',monospace;letter-spacing:.06em;text-transform:uppercase;background:#7FA59A;color:#16241E;padding:4px 10px;border-radius:999px"
						>Popular</span
					>
					<h3
						style="font-size:14px;font-weight:700;font-family:'Martian Mono',monospace;letter-spacing:.04em;color:#7FA59A;text-transform:uppercase;margin:0"
					>
						Clínica
					</h3>
					<div style="font-size:14px;color:#AEB8C0;margin:8px 0 20px">
						Para clínicas com equipe e recepção.
					</div>
					<div style="font-size:40px;font-weight:800;letter-spacing:-.02em;color:#fff">
						R$&nbsp;{precoClinica}
					</div>
					<div style="font-size:13px;color:#8F99A2;margin:4px 0 22px">{periodo}</div>
					<a
						href="/criar-conta"
						class="cn-hover-white"
						style="display:block;text-align:center;box-sizing:border-box;width:100%;background:#fff;color:#212A37;font-size:15px;font-weight:700;padding:12px;border-radius:11px;margin-bottom:22px"
						>Começar grátis</a
					>
					<div style="display:flex;flex-direction:column;gap:11px;font-size:14px;color:#D3DAE0">
						{#each clinicaFeatures as f (f)}
							<div style="display:flex;gap:9px">{@render check('#7FA59A', 18)}{f}</div>
						{/each}
					</div>
				</div>
				<!-- Rede -->
				<div style="background:#fff;border:1px solid #E6E2D8;border-radius:20px;padding:30px">
					<h3
						style="font-size:14px;font-weight:700;font-family:'Martian Mono',monospace;letter-spacing:.04em;color:#5C6670;text-transform:uppercase;margin:0"
					>
						Rede
					</h3>
					<div style="font-size:14px;color:#696356;margin:8px 0 20px">
						Para redes com múltiplas unidades.
					</div>
					<div style="font-size:32px;font-weight:800;letter-spacing:-.02em">Sob consulta</div>
					<div style="font-size:13px;color:#696356;margin:4px 0 22px">plano personalizado</div>
					<a
						href="/criar-conta"
						class="cn-hover-border"
						style="display:block;text-align:center;box-sizing:border-box;width:100%;background:#fff;border:1px solid #D9D4C7;color:#212A37;font-size:15px;font-weight:600;padding:12px;border-radius:11px;margin-bottom:22px"
						>Falar com vendas</a
					>
					<div style="display:flex;flex-direction:column;gap:11px;font-size:14px;color:#3D454F">
						{#each redeFeatures as f (f)}
							<div style="display:flex;gap:9px">{@render check('#7FA59A', 18)}{f}</div>
						{/each}
					</div>
				</div>
			</div>
		</div>
	</section>

	<!-- DÚVIDAS (doc 57) — depois do preço e antes do último pedido: é onde a objeção aparece.
	     `<details>` nativo, não sanfona de JavaScript: funciona sem hidratar, o teclado já sabe
	     operar, o buscador lê a resposta mesmo fechada e não há altura a reservar (logo, nenhum
	     risco de voltar a mexer no CLS que esta entrega zerou). -->
	<section id="duvidas" class="cn-sect" style="padding:110px 0;background:#F6F4EF">
		<div class="cn-wrap" style="max-width:1160px;margin:0 auto;padding:0 30px">
			<!-- Cabeçalho centrado, como o dos planos logo acima — as duas seções fecham a página
			     e falavam com alinhamentos diferentes. -->
			<div style="max-width:680px;margin:0 auto;text-align:center">
				<div
					style="font-family:'Martian Mono',monospace;font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:#4A6E62;margin-bottom:22px"
				>
					Dúvidas
				</div>
				<h2
					style="font-size:44px;line-height:1.1;letter-spacing:-.03em;font-weight:800;margin:0;text-wrap:balance"
				>
					O que perguntam antes de assinar.
				</h2>
			</div>
			<!-- A coluna é centrada, mas pergunta e resposta seguem alinhadas à esquerda: texto
			     corrido centrado obriga o olho a procurar o início de cada linha. E a largura caiu
			     de 860 para 680 (a mesma do cabeçalho) porque agora é o container que limita a
			     medida da resposta — daí o `max-width` em `ch` ter saído do CSS. -->
			<div class="cn-faq" style="margin:52px auto 0;max-width:680px">
				{#each FAQ as item, i (item.id)}
					<details open={i === 0}>
						<summary>
							<h3>{item.pergunta}</h3>
							<span class="cn-faq-sinal" aria-hidden="true"></span>
						</summary>
						<p>{item.resposta}</p>
					</details>
				{/each}
			</div>
			<div style="margin-top:40px;font-size:16px;color:#696356;text-align:center">
				Ficou outra dúvida? <a
					href="/criar-conta"
					style="color:#212A37;font-weight:600;text-decoration:underline;text-underline-offset:3px"
					>Comece o teste grátis</a
				> e fale com a gente durante os 14 dias.
			</div>
		</div>
	</section>

	<!-- CTA final -->
	<section
		class="cn-sect"
		style="position:relative;padding:120px 30px;background:#212A37;text-align:center;overflow:hidden"
	>
		<div
			style="position:absolute;top:-100px;right:-60px;width:380px;height:380px;background:radial-gradient(circle,rgba(127,165,154,.4),transparent 70%);animation:cnBlob 17s ease-in-out infinite;pointer-events:none"
		></div>
		<div
			style="position:absolute;bottom:-120px;left:-40px;width:340px;height:340px;background:radial-gradient(circle,rgba(58,90,120,.5),transparent 70%);animation:cnBlob 20s ease-in-out infinite reverse;pointer-events:none"
		></div>
		<div style="position:relative">
			<span style="display:inline-block;margin-bottom:28px;animation:cnBreathe 5s ease-in-out infinite"
				><Mark class="h-13 w-auto" /></span
			>
			<h2
				style="font-size:56px;line-height:1.08;letter-spacing:-.03em;font-weight:800;color:#fff;margin:0 auto;max-width:720px;text-wrap:balance"
			>
				Deixe sua clínica respirar.
			</h2>
			<p style="font-size:19px;color:#B7C0C8;margin:20px auto 36px;max-width:480px">
				14 dias grátis, sem cartão de crédito. Configure em minutos e sinta a diferença já na
				primeira semana.
			</p>
			<div style="display:flex;flex-wrap:wrap;gap:12px;justify-content:center">
				<a
					href="/criar-conta"
					class="cn-hover-white"
					style="display:inline-flex;align-items:center;gap:10px;background:#fff;color:#212A37;font-size:17px;font-weight:700;padding:17px 30px;border-radius:14px"
					>Começar agora
					<svg
						width="19"
						height="19"
						viewBox="0 0 24 24"
						fill="none"
						stroke="currentColor"
						stroke-width="2"
						stroke-linecap="round"
						stroke-linejoin="round"
						><line x1="5" y1="12" x2="19" y2="12"></line><polyline points="12 5 19 12 12 19"
						></polyline></svg
					></a
				>
				<a
					href="/entrar"
					class="cn-hover-glass"
					style="background:rgba(255,255,255,.1);border:1px solid rgba(255,255,255,.25);color:#fff;font-size:17px;font-weight:600;padding:17px 26px;border-radius:14px"
					>Já tenho conta</a
				>
			</div>
		</div>
	</section>

	</main>

	<!-- FOOTER -->
	<footer class="cn-foot" style="border-top:1px solid #E6E2D8;padding:44px 0;background:#F6F4EF">
		<div
			class="cn-footrow"
			style="max-width:1160px;margin:0 auto;padding:0 30px;display:flex;flex-wrap:wrap;gap:24px;align-items:center;justify-content:space-between"
		>
			<Logo class="h-6.5 w-auto" />
			<div style="display:flex;gap:24px;font-size:14px;color:#696356;flex-wrap:wrap">
				<a href="#recursos" style="transition:color .2s">Recursos</a>
				<a href="#precos" style="transition:color .2s">Planos</a>
				<a href="#duvidas" style="transition:color .2s">Dúvidas</a>
				<a href="/entrar" style="transition:color .2s">Entrar</a>
			</div>
			<div style="font-size:13px;color:#696356">© 2026 Cinetra · Feito para clínicas de fisioterapia</div>
		</div>
	</footer>
</div>
