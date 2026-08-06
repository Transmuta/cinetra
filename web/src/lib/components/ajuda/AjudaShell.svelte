<script lang="ts">
	// A casca da central de ajuda (doc 108 §2) — a MESMA das páginas públicas.
	//
	// Ela nasceu com os tokens do app (`surface`/`ink`), pelo argumento de que quem lê está com o
	// sistema aberto ao lado. Passou a ser a casca da landing por decisão de 2026-08-06: a central
	// é uma página pública, alcançável sem sessão e compartilhável por link, e no meio do site ela
	// destoava — topo diferente, rodapé diferente, tipografia diferente. Quem chega pela home tem
	// de sentir que continua no mesmo lugar.
	//
	// Consequência assumida: a central segue a paleta papel/navy da marca e **não tem tema
	// escuro**, como `/termos` e `/privacidade`. O tópico do tema mostra o escuro por print.
	import Seo from '$lib/components/Seo.svelte';
	import FlowArt from '$lib/components/cinetra/FlowArt.svelte';
	import SiteHeader from '$lib/components/cinetra/SiteHeader.svelte';
	import SiteFooter from '$lib/components/cinetra/SiteFooter.svelte';
	import ArrowLeft from '@lucide/svelte/icons/arrow-left';
	import '$lib/styles/cinetra.css';

	// 1160px é a MEDIDA DO SITE: `SiteHeader`, `SiteFooter` e `LegalPage` usam a mesma, com os
	// mesmos 30px de recuo. A central nasceu com 1240 e o desalinhamento aparecia justamente onde
	// mais incomoda — o conteúdo começava antes do logotipo e terminava depois do rodapé.
	import type { Snippet } from 'svelte';

	let {
		titulo,
		subtitulo,
		descricao,
		canonical,
		origem,
		/** Chapéu do herói: "Central de ajuda" no índice, o nome da seção no tópico. */
		chapeu = 'Central de ajuda',
		logado = false,
		/** A coluna da esquerda. Ausente = conteúdo em coluna única (o índice). */
		lateral = undefined,
		children
	}: {
		titulo: string;
		subtitulo: string;
		descricao: string;
		canonical: string;
		origem: string;
		chapeu?: string;
		logado?: boolean;
		lateral?: Snippet;
		children: Snippet;
	} = $props();
</script>

<Seo titulo="{titulo} · Ajuda Cinetra" {descricao} {canonical} {origem} />

<div class="cn-root" style="min-height:100dvh">
	<a href="#conteudo" class="cn-skip">Pular para o conteúdo</a>
	<SiteHeader prefixo="/" />

	<main id="conteudo">
		<!-- Herói na mesma família do das páginas legais: mais baixo que o da landing (aqui o
		     assunto é leitura, não conversão), mesma arte e mesmo navy. -->
		<section style="position:relative;overflow:hidden;background:#212A37">
			<div style="position:absolute;inset:0"><FlowArt k={titulo} /></div>
			<div
				style="position:absolute;inset:0;background:linear-gradient(180deg,rgba(33,42,55,.62) 0%,rgba(33,42,55,.4) 55%,rgba(33,42,55,.72) 100%);pointer-events:none"
			></div>
			<div
				class="cn-sect"
				style="position:relative;max-width:1160px;margin:0 auto;padding:64px 30px 56px"
			>
				<div style="max-width:760px;animation:cnRise .7s ease both">
					<div
						style="font-family:'Martian Mono',monospace;font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:#7FA59A;margin-bottom:18px"
					>
						{chapeu}
					</div>
					<h1
						class="cn-legal-h1"
						style="font-size:46px;line-height:1.07;letter-spacing:-.03em;font-weight:800;color:#fff;margin:0;text-wrap:balance"
					>
						{titulo}
					</h1>
					<p
						style="font-size:18px;line-height:1.55;color:#C6D0D5;margin:18px 0 0;max-width:620px;text-wrap:pretty"
					>
						{subtitulo}
					</p>

					<a
						href={logado ? '/agenda' : '/entrar'}
						class="cn-hover-glass"
						style="display:inline-flex;align-items:center;gap:8px;margin-top:26px;padding:9px 15px;border:1px solid rgba(255,255,255,.28);border-radius:10px;color:#fff;font-size:14px;font-weight:600"
					>
						<ArrowLeft size={15} />
						{logado ? 'Voltar ao sistema' : 'Entrar no sistema'}
					</a>
				</div>
			</div>
		</section>

		<section class="cn-sect" style="padding:56px 0 84px;background:#F6F4EF">
			<div
				class="cn-wrap cn-ajudagrid"
				style="max-width:1160px;margin:0 auto;padding:0 30px;{lateral
					? 'display:grid;grid-template-columns:264px 1fr;gap:52px;align-items:start'
					: ''}"
			>
				{#if lateral}
					{@render lateral()}
				{/if}
				<div style="min-width:0">
					{@render children()}
				</div>
			</div>
		</section>
	</main>

	<SiteFooter />
</div>
