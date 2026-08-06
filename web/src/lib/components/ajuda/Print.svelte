<script lang="ts">
	// A imagem de um passo da central de ajuda (doc 108 §4).
	//
	// Três responsabilidades, todas por causa de como esta página é lida:
	//
	//  1. **Dimensão declarada.** As prints são grandes e chegam depois do texto; sem `width`/
	//     `height`, cada uma que carrega empurra o parágrafo que a pessoa está lendo. A dimensão
	//     vem do manifesto (medida na captura), não escrita à mão.
	//  2. **Ampliação.** A tela fotografada tem 1440px de largura e a coluna de leitura tem ~760.
	//     Numa print de tela cheia, o botão que o texto cita fica com 8px — legível só ampliando.
	//     Daí a imagem ser clicável e abrir em tamanho real sobre a página.
	//  3. **Ausência visível.** Print citada e não gerada não pode virar quadrado vazio: o leitor
	//     não saberia se o problema é a internet dele. O lugar da imagem vira uma nota honesta.
	import { caminhoDaPrint, print as meta } from '$lib/ajuda/prints';
	import Maximize2 from '@lucide/svelte/icons/maximize-2';
	import X from '@lucide/svelte/icons/x';

	let {
		id,
		alt,
		legenda = undefined
	}: { id: string; alt: string; legenda?: string } = $props();

	const info = $derived(meta(id));
	const src = $derived(caminhoDaPrint(id));

	let ampliada = $state(false);
</script>

<svelte:window onkeydown={(e) => e.key === 'Escape' && (ampliada = false)} />

<figure style="margin:22px 0">
	{#if src && info}
		<!-- `<button>` e não `<img onclick>`: ampliar é ação, e ação precisa de foco, Enter e
		     espaço para quem navega por teclado. -->
		<button
			type="button"
			class="cn-print"
			style="position:relative"
			onclick={() => (ampliada = true)}
			aria-label="Ampliar imagem: {alt}"
		>
			<img {src} {alt} width={info.largura} height={info.altura} loading="lazy" decoding="async" />
			<span class="cn-print-lupa"><Maximize2 size={13} /> Ampliar</span>
		</button>
	{:else}
		<div
			style="display:grid;place-items:center;padding:40px 16px;border:1px dashed #dcd8ce;border-radius:14px;background:#fff;color:#8a8375;font-size:14px;text-align:center"
		>
			Imagem desta etapa em preparo.
		</div>
	{/if}

	{#if legenda}
		<figcaption style="margin-top:9px;font-size:14px;line-height:1.5;color:#736E63">
			{legenda}
		</figcaption>
	{/if}
</figure>

{#if ampliada && src}
	<!-- Sem `<dialog>`: ele exige `showModal()` imperativo e traz um backdrop próprio que brigaria
	     com o daqui. O que o modal precisa dar — Esc, clique fora e foco no botão de fechar — está
	     resolvido explicitamente abaixo. -->
	<div
		class="cn-lightbox"
		role="button"
		tabindex="-1"
		aria-label="Fechar imagem ampliada"
		onclick={() => (ampliada = false)}
		onkeydown={(e) => e.key === 'Enter' && (ampliada = false)}
	>
		<button
			type="button"
			class="cn-lightbox-fechar"
			onclick={() => (ampliada = false)}
			>{@render fechar()}</button
		>
		<!-- Sem handler próprio: o overlay inteiro fecha, e o cursor `zoom-out` promete exatamente
		     isso. Parar a propagação aqui faria o clique na imagem não fazer nada — o gesto mais
		     provável de quem quer sair. -->
		<img {src} {alt} />
	</div>
{/if}

{#snippet fechar()}
	<X size={15} /> Fechar
{/snippet}
