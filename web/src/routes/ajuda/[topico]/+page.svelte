<script lang="ts">
	// Um tópico. À esquerda, os tópicos irmãos da seção com o atual marcado; à direita, o passo a
	// passo. A navegação lateral existe porque quem entra num tópico quase sempre precisa do
	// vizinho em seguida ("marcar" → "remarcar" → "cancelar"), e voltar ao índice para isso é um
	// clique a mais em cada troca.
	import AjudaShell from '$lib/components/ajuda/AjudaShell.svelte';
	import Corpo from '$lib/components/ajuda/Corpo.svelte';
	import ChevronLeft from '@lucide/svelte/icons/chevron-left';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import { topicoPorId, topicosDaSecao, SECOES } from '$lib/ajuda';
	import type { PageData } from './$types';

	let { data }: { data: PageData } = $props();

	const irmaos = $derived(topicosDaSecao(data.topico.secao));
	const relacionados = $derived(
		(data.topico.vejaTambem ?? []).map(topicoPorId).filter((t) => t !== undefined)
	);
	// As outras seções, para quem chegou por busca e precisa sair daqui sem voltar ao índice.
	const outras = $derived(SECOES.filter((s) => s.id !== data.topico.secao));
</script>

<AjudaShell
	titulo={data.topico.titulo}
	subtitulo={data.topico.resumo}
	descricao={data.topico.resumo}
	chapeu={data.secao.titulo}
	canonical={data.canonical}
	origem={data.origem}
	logado={data.logado}
>
	{#snippet lateral()}
		<nav class="cn-ajudanav" aria-label="Tópicos desta seção">
			<p class="cn-ajudanav-titulo">{data.secao.titulo}</p>
			<ul>
				{#each irmaos as t (t.id)}
					<li>
						<a href="/ajuda/{t.id}" aria-current={t.id === data.topico.id ? 'page' : undefined}>
							{t.titulo}
						</a>
					</li>
				{/each}
			</ul>

			<div class="cn-ajudanav-secao">
				<p class="cn-ajudanav-titulo">Outras seções</p>
				<ul>
					{#each outras as s (s.id)}
						<li><a href="/ajuda#{s.id}">{s.titulo}</a></li>
					{/each}
				</ul>
			</div>
		</nav>
	{/snippet}

	<article class="cn-legal" style="max-width:760px">
		<!-- A quem o tópico serve, antes do primeiro passo: "isso é comigo?" vem antes de "como
		     faço", e responder depois do passo 4 é responder tarde. -->
		<p
			style="display:flex;flex-wrap:wrap;align-items:center;gap:7px;margin:0 0 20px;font-size:13px;color:#736E63"
		>
			<span>Para:</span>
			{#each data.papeis as papel (papel)}
				<span
					style="padding:3px 9px;border-radius:999px;background:#ECE9E1;color:#575249;font-weight:600"
					>{papel}</span
				>
			{/each}
		</p>

		<Corpo blocos={data.topico.blocos} />

		{#if relacionados.length > 0}
			<section style="margin-top:44px">
				<h2 style="font-size:20px;margin-bottom:10px">Veja também</h2>
				<ul>
					{#each relacionados as t (t.id)}
						<li>
							<a href="/ajuda/{t.id}" style="color:#4E7468;font-weight:600">{t.titulo}</a>
						</li>
					{/each}
				</ul>
			</section>
		{/if}

		<nav
			style="display:flex;flex-wrap:wrap;justify-content:space-between;gap:14px;margin-top:44px;padding-top:22px;border-top:1px solid #DCD8CE"
			aria-label="Outros tópicos"
		>
			{#if data.anterior}
				<a
					href="/ajuda/{data.anterior.id}"
					style="display:inline-flex;align-items:center;gap:7px;max-width:46%;font-size:14.5px;color:#575249"
				>
					<ChevronLeft size={15} />
					<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap"
						>{data.anterior.titulo}</span
					>
				</a>
			{:else}
				<span></span>
			{/if}

			{#if data.proximo}
				<a
					href="/ajuda/{data.proximo.id}"
					style="display:inline-flex;align-items:center;gap:7px;max-width:46%;font-size:14.5px;color:#575249"
				>
					<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap"
						>{data.proximo.titulo}</span
					>
					<ChevronRight size={15} />
				</a>
			{/if}
		</nav>
	</article>
</AjudaShell>
