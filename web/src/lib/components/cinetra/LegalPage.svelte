<script lang="ts">
	// Casca dos documentos legais (/privacidade e /termos). As duas rotas são a MESMA página com
	// um dado diferente: o conteúdo mora em `$lib/legal.ts` e aqui só se desenha.
	//
	// O sumário e o corpo saem do mesmo array, de propósito. Índice escrito à mão ao lado de um
	// texto de 3 mil palavras é onde nasce a âncora quebrada que ninguém percebe lendo a página.
	import Seo from '../Seo.svelte';
	import FlowArt from './FlowArt.svelte';
	import SiteHeader from './SiteHeader.svelte';
	import SiteFooter from './SiteFooter.svelte';
	import { documentoPorCaminho, VERSAO, type Documento } from '$lib/legal';
	import '$lib/styles/cinetra.css';

	let {
		doc,
		canonical,
		origem
	}: { doc: Documento; canonical: string; origem: string } = $props();

	// O documento par (quem abre a política costuma querer os termos em seguida).
	const par = $derived(documentoPorCaminho(doc.par));
</script>

<Seo titulo="{doc.titulo} · Cinetra" descricao={doc.descricao} {canonical} {origem} />

<div class="cn-root" style="min-height:100dvh">
	<a href="#conteudo" class="cn-skip">Pular para o conteúdo</a>
	<!-- `prefixo="/"`: aqui não existe seção de planos para `#precos` encontrar. -->
	<SiteHeader prefixo="/" />

	<main id="conteudo">
		<!-- Herói. Mais baixo que o da landing (o assunto é leitura, não conversão), mas com a
		     mesma arte e o mesmo navy: quem chega aqui pelo rodapé não deve sentir que saiu do site. -->
		<section style="position:relative;overflow:hidden;background:#212A37">
			<div style="position:absolute;inset:0"><FlowArt k={doc.id} /></div>
			<div
				style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(33,42,55,.62) 0%,rgba(33,42,55,.4) 55%,rgba(33,42,55,.72) 100%);pointer-events:none"
			></div>
			<div
				class="cn-sect"
				style="position:relative;max-width:1160px;margin:0 auto;padding:78px 30px 66px"
			>
				<div style="max-width:720px;animation:cnRise .7s ease both">
					<div
						style="font-family:'Martian Mono',monospace;font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:#7FA59A;margin-bottom:20px"
					>
						Documentos
					</div>
					<h1
						class="cn-legal-h1"
						style="font-size:52px;line-height:1.06;letter-spacing:-.03em;font-weight:800;color:#fff;margin:0;text-wrap:balance"
					>
						{doc.titulo}
					</h1>
					<p
						style="font-size:19px;line-height:1.55;color:#C6D0D5;margin:20px 0 0;max-width:560px;text-wrap:pretty"
					>
						{doc.subtitulo}
					</p>
					<p
						style="font-family:'Martian Mono',monospace;font-size:12.5px;color:#8F99A2;margin:26px 0 0"
					>
						Atualizado em {doc.atualizacao} · versão {VERSAO}
					</p>
				</div>
			</div>
		</section>

		<section class="cn-sect" style="padding:66px 0 90px;background:#F6F4EF">
			<div
				class="cn-wrap cn-legalgrid"
				style="max-width:1160px;margin:0 auto;padding:0 30px;display:grid;grid-template-columns:248px 1fr;gap:56px;align-items:start"
			>
				<!-- Sumário. `sticky` no desktop (o texto é longo e a pessoa procura uma seção
				     específica); no mobile vira uma lista comum no topo, ver cinetra.css. -->
				<nav class="cn-sumario" aria-labelledby="sumario">
					<h2
						id="sumario"
						style="font-family:'Martian Mono',monospace;font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:#4A6E62;margin:0 0 16px;font-weight:700"
					>
						Nesta página
					</h2>
					<ol>
						{#each doc.secoes as secao (secao.id)}
							<li><a href="#{secao.id}">{secao.titulo}</a></li>
						{/each}
					</ol>
				</nav>

				<div class="cn-legal">
					{#each doc.secoes as secao (secao.id)}
						<!-- `scroll-margin-top` no próprio alvo: o topo é sticky, e sem isso a âncora
						     para o título embaixo da barra. -->
						<section id={secao.id} style="scroll-margin-top:88px">
							<h2>{secao.titulo}</h2>
							{#each secao.blocos as bloco, i (i)}
								{#if typeof bloco === 'string'}
									<p>{bloco}</p>
								{:else}
									<ul>
										{#each bloco.lista as item (item)}
											<li>{item}</li>
										{/each}
									</ul>
								{/if}
							{/each}
						</section>
					{/each}

					{#if par}
						<a href={par.caminho} class="cn-legal-par">
							<span
								style="font-family:'Martian Mono',monospace;font-size:11.5px;letter-spacing:.14em;text-transform:uppercase;color:#4A6E62"
								>Leia também</span
							>
							<span style="font-size:19px;font-weight:700;letter-spacing:-.01em">{par.titulo}</span>
							<span style="font-size:15px;color:#696356">{par.subtitulo}</span>
						</a>
					{/if}
				</div>
			</div>
		</section>
	</main>

	<SiteFooter />
</div>
