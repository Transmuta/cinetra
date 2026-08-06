<script lang="ts">
	// A busca da central. Client-side sobre os ~44 tópicos carregados: nada de índice remoto —
	// eles cabem em memória, e assim a busca funciona também com o app instalado e sem rede,
	// que é justamente quando alguém procura "como faço" no celular da recepção.
	//
	// **Paleta da marca em hex, não tokens do app.** A central usa a casca das páginas públicas, que
	// é papel/navy FIXO — ela não tem tema escuro. Com `bg-surface`/`text-ink` o campo seguia o tema
	// do aparelho e virava uma caixa preta no meio da página creme (achado de 2026-08-06). Mesma
	// razão pela qual `AuthForm` escreve cor à mão, e a mesma isenção em `cor-crua.test.ts`.
	import Search from '@lucide/svelte/icons/search';
	import { buscar, SECAO_POR_ID, type Topico } from '$lib/ajuda';

	let termo = $state('');
	const achados = $derived<Topico[]>(buscar(termo).slice(0, 12));
	const buscando = $derived(termo.trim().length > 0);
</script>

<div style="position:relative">
	<label style="display:block">
		<span class="cn-sr">Buscar na ajuda</span>
		<span
			style="position:absolute;left:15px;top:23px;transform:translateY(-50%);color:#8A8375;pointer-events:none"
		>
			<Search size={16} />
		</span>
		<input
			bind:value={termo}
			type="search"
			placeholder="Buscar — ex.: remarcar, encaixe, falta"
			style="width:100%;height:46px;padding:0 15px 0 42px;border:1px solid #D9D4C7;border-radius:11px;background:#fff;color:#212A37;font-size:15.5px"
		/>
	</label>

	{#if buscando}
		<div style="margin-top:12px" role="region" aria-live="polite" aria-label="Resultados da busca">
			{#if achados.length === 0}
				<p
					style="margin:0;padding:13px 15px;border:1px solid #E6E2D8;border-radius:11px;background:#fff;font-size:15px;color:#575249"
				>
					Nada encontrado para “{termo}”. Tente uma palavra que você viu na tela.
				</p>
			{:else}
				<ul
					style="margin:0;padding:0;list-style:none;overflow:hidden;border:1px solid #E6E2D8;border-radius:11px;background:#fff"
				>
					{#each achados as t (t.id)}
						<li style="border-bottom:1px solid #F0EDE5">
							<a href="/ajuda/{t.id}" class="cn-busca-item" style="display:block;padding:11px 15px">
								<span style="display:block;font-size:15px;font-weight:700;color:#212A37"
									>{t.titulo}</span
								>
								<span style="display:block;margin-top:2px;font-size:13.5px;color:#736E63">
									{SECAO_POR_ID[t.secao].titulo} · {t.resumo}
								</span>
							</a>
						</li>
					{/each}
				</ul>
			{/if}
		</div>
	{/if}
</div>
