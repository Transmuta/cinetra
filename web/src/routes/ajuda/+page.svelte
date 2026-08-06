<script lang="ts">
	// O índice da central: busca no alto, seções na coluna da esquerda, cartões à direita.
	//
	// O índice sai de `indice()`, nunca de uma lista escrita aqui — a mesma razão do sumário dos
	// documentos legais: índice à mão ao lado de conteúdo em outro arquivo é onde nasce o item que
	// aponta para o tópico que já não existe.
	import AjudaShell from '$lib/components/ajuda/AjudaShell.svelte';
	import Busca from '$lib/components/ajuda/Busca.svelte';
	import { indice } from '$lib/ajuda';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	const grupos = indice();
	const total = grupos.reduce((n, g) => n + g.topicos.length, 0);
</script>

<AjudaShell
	titulo="Central de ajuda"
	subtitulo="Como usar o Cinetra no dia a dia da clínica — do primeiro acesso à conferência dos números do mês."
	descricao="Guias passo a passo do Cinetra: agenda, pacientes, pacotes, fila de espera, equipe e configurações."
	chapeu="Guias do sistema"
	canonical={data.canonical}
	origem={data.origem}
	logado={data.logado}
>
	{#snippet lateral()}
		<nav class="cn-ajudanav" aria-label="Seções da ajuda">
			<p class="cn-ajudanav-titulo">Seções</p>
			<ul>
				{#each grupos as { secao } (secao.id)}
					<li><a href="#{secao.id}">{secao.titulo}</a></li>
				{/each}
			</ul>
		</nav>
	{/snippet}

	<div style="margin-bottom:30px">
		<Busca />
		<p style="margin:10px 0 0;font-size:13.5px;color:#736E63">
			{total} guias · atualizados junto com o sistema
		</p>
	</div>

	<div style="display:flex;flex-direction:column;gap:38px">
		{#each grupos as { secao, topicos } (secao.id)}
			<!-- `scroll-margin-top`: o topo do site é sticky, e sem isto a âncora para o título da
			     seção embaixo da barra. Mesma correção do sumário das páginas legais. -->
			<section id={secao.id} style="scroll-margin-top:88px">
				<h2
					style="font-size:23px;line-height:1.25;letter-spacing:-.015em;font-weight:700;color:#212A37;margin:0"
				>
					{secao.titulo}
				</h2>
				<p style="margin:5px 0 0;font-size:15.5px;line-height:1.55;color:#575249">
					{secao.resumo}
				</p>

				<ul
					style="margin:16px 0 0;padding:0;list-style:none;display:grid;gap:10px;grid-template-columns:repeat(auto-fill,minmax(280px,1fr))"
				>
					{#each topicos as t (t.id)}
						<li>
							<a
								href="/ajuda/{t.id}"
								class="cn-hover-border"
								style="display:block;height:100%;padding:14px 16px;background:#fff;border:1px solid #E6E2D8;border-radius:14px"
							>
								<span
									style="display:block;font-size:15.5px;font-weight:700;color:#212A37;letter-spacing:-.01em"
									>{t.titulo}</span
								>
								<span style="display:block;margin-top:4px;font-size:14px;line-height:1.5;color:#736E63"
									>{t.resumo}</span
								>
							</a>
						</li>
					{/each}
				</ul>
			</section>
		{/each}
	</div>
</AjudaShell>
