<script lang="ts">
	// O corpo de um tópico: desenha os blocos do conteúdo, um tipo por vez.
	//
	// Um componente só para os seis tipos de bloco, e não um por tipo, porque a decisão de "o que
	// vem depois de quê" é do CONTEÚDO — quem monta a página não escolhe ordem nem mistura. Isso é
	// o que permite ao gate varrer o conteúdo sabendo que a tela mostra exatamente aquilo.
	//
	// Cor em hex, da paleta da marca. A central é papel/navy FIXO (a casca é a das páginas
	// públicas): com `text-ink`/`border-edge` o texto e as bordas seguiam o tema do aparelho e
	// sumiam sobre o creme no modo escuro. Ver a nota em `Busca.svelte`.
	import Aviso from './Aviso.svelte';
	import Print from './Print.svelte';
	import type { Bloco } from '$lib/ajuda/tipos';

	let { blocos }: { blocos: readonly Bloco[] } = $props();
</script>

{#each blocos as bloco, i (i)}
	{#if bloco.tipo === 'texto'}
		<p style="margin:14px 0;font-size:16.5px;line-height:1.68;color:#575249">{bloco.texto}</p>
	{:else if bloco.tipo === 'lista'}
		<!-- Sem `style` próprio: o `cn-legal` da página já desenha `ul`/`li` — inclusive o ponto
		     sálvia do marcador, que é o mesmo dos documentos legais. -->
		<ul>
			{#each bloco.itens as item (item)}
				<li>{item}</li>
			{/each}
		</ul>
	{:else if bloco.tipo === 'passos'}
		<!-- `<ol>`: a ordem é a informação. Numeração desenhada à mão perderia isso para quem lê
		     por leitor de tela, que anuncia "lista de 6 itens, item 3". -->
		<ol class="cn-passos" style="margin:22px 0;padding:0;display:flex;flex-direction:column;gap:22px">
			{#each bloco.passos as passo, n (n)}
				<li style="display:flex;gap:14px;padding-left:0">
					<span class="cn-passo-num" aria-hidden="true">{n + 1}</span>
					<div style="min-width:0;flex:1">
						<p style="margin:0;font-size:16.5px;line-height:1.68;color:#3D454F">{passo.texto}</p>
						{#if passo.print}
							<Print id={passo.print} alt={passo.alt ?? ''} legenda={passo.legenda} />
						{:else if passo.legenda}
							<p style="margin:7px 0 0;font-size:14px;line-height:1.5;color:#736E63">
								{passo.legenda}
							</p>
						{/if}
					</div>
				</li>
			{/each}
		</ol>
	{:else if bloco.tipo === 'aviso'}
		<Aviso tom={bloco.tom} texto={bloco.texto} />
	{:else if bloco.tipo === 'print'}
		<Print id={bloco.print} alt={bloco.alt} legenda={bloco.legenda} />
	{:else if bloco.tipo === 'tabela'}
		<!-- Rolagem própria: a central é lida no celular, e tabela de três colunas não cabe em
		     390px. Sem isto, a PÁGINA inteira passa a rolar de lado. -->
		<div style="margin:20px 0;overflow-x:auto">
			<table
				style="width:100%;min-width:420px;border-collapse:collapse;font-size:15px;line-height:1.55"
			>
				<thead>
					<tr style="border-bottom:1px solid #DCD8CE;text-align:left">
						{#each bloco.colunas as coluna (coluna)}
							<th scope="col" style="padding:8px 12px 8px 0;font-weight:700;color:#736E63"
								>{coluna}</th
							>
						{/each}
					</tr>
				</thead>
				<tbody>
					{#each bloco.linhas as linha, l (l)}
						<tr style="border-bottom:1px solid #E6E2D8;vertical-align:top">
							{#each linha as celula, c (c)}
								{#if c === 0}
									<th
										scope="row"
										style="padding:9px 12px 9px 0;text-align:left;font-weight:600;color:#212A37"
										>{celula}</th
									>
								{:else}
									<td style="padding:9px 12px 9px 0;color:#575249">{celula}</td>
								{/if}
							{/each}
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
{/each}
