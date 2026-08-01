<script lang="ts">
	// O bloco de endereço, uma vez só: CEP com busca, autopreenchimento e os campos que ele
	// preenche.
	//
	// A **máquina** já morava em `$lib/cep.svelte` (doc 94 §D-1) — ela estava escrita duas vezes,
	// byte a byte a menos do nome de uma variável. O que ficou de fora daquela extração foi o
	// MARKUP, e ele voltou a ser o problema quando a clínica passou a ter endereço estruturado
	// (doc 52 §9.1.4): seria a terceira cópia dos mesmos sete campos, do mesmo texto de status do
	// CEP e da mesma máscara de UF.
	//
	// ## Quem usa, e quem não usa
	//
	// `PatientForm` e o formulário da clínica usam este componente — o layout deles é o mesmo
	// (seção larga, CEP e logradouro lado a lado). O `ProfessionalForm` **não**: ele desenha o
	// endereço numa coluna estreita de uma grade de duas, e forçar este layout lá mudaria o
	// desenho daquela tela sem ninguém ter pedido. Uma prop de layout para reconciliar os dois
	// seria mais código do que a duplicação que ela evita.
	//
	// ## Por que `campos` e não sete `bind:`
	//
	// Porque a consulta de CEP escreve em quatro deles de uma vez. Sete `$bindable` significariam
	// sete props a repassar em cada uso e uma assinatura que muda toda vez que um campo entra;
	// um objeto `$state` do host é o mesmo proxy reativo dos dois lados, e mutá-lo aqui atualiza
	// lá — que é exatamente o que `criarCep` já faz.
	import { untrack } from 'svelte';
	import { criarCep, type CamposDeEndereco } from '$lib/cep.svelte';
	import { maskUf } from '$lib/masks';

	interface Props {
		/** O objeto `$state` do formulário anfitrião. Mutado no lugar. */
		campos: CamposDeEndereco & { numero: string; complemento: string };
		/** A classe dos inputs, para herdar o controle do formulário anfitrião. */
		inputCls: string;
		/** "Endereço residencial" na ficha, "Endereço" na clínica. */
		rotuloEndereco?: string;
	}

	let { campos: f, inputCls, rotuloEndereco = 'Endereço' }: Props = $props();

	// `untrack` porque a máquina se prende ao OBJETO, não a um valor: o anfitrião passa sempre o
	// mesmo proxy `$state` e nunca o troca, então reconstruir `criarCep` a cada leitura de `f`
	// jogaria fora o status do CEP e a guarda de resposta atrasada no meio de uma consulta.
	const cep = untrack(() => criarCep(f));
</script>

{#snippet rotulo(text: string)}
	<span class="mb-1 block text-rotulo font-medium text-muted">{text}</span>
{/snippet}

<div class="grid grid-cols-1 gap-3 md:grid-cols-[0.9fr_2.3fr]">
	<label class="block">
		{@render rotulo('CEP')}
		<input
			value={f.cep}
			oninput={cep.aoDigitar}
			onblur={() => cep.consultar(f.cep)}
			inputmode="numeric"
			placeholder="00000-000"
			class="{inputCls} font-mono"
		/>
	</label>
	<label class="block">
		{@render rotulo(rotuloEndereco)}
		<input
			bind:value={f.endereco}
			placeholder="Preenchido automaticamente pelo CEP"
			class={inputCls}
		/>
	</label>
</div>

{#if cep.status}
	<span
		class="mt-1 block text-meta {cep.status === 'ok'
			? 'text-accent-text'
			: cep.status === 'loading'
				? 'text-muted'
				: 'text-danger'}"
	>
		{cep.status === 'loading'
			? 'Buscando endereço…'
			: cep.status === 'ok'
				? 'Endereço preenchido pelo CEP'
				: cep.status === 'notfound'
					? 'CEP não encontrado — preencha manualmente'
					: 'Não foi possível consultar o CEP agora'}
	</span>
{/if}

<div class="mt-3 grid grid-cols-2 gap-3 md:grid-cols-[1.5fr_1.6fr_0.5fr_0.7fr]">
	<label class="block">
		{@render rotulo('Bairro')}
		<input bind:value={f.bairro} class={inputCls} />
	</label>
	<label class="block">
		{@render rotulo('Cidade')}
		<input bind:value={f.cidade} class={inputCls} />
	</label>
	<label class="block">
		{@render rotulo('UF')}
		<input
			value={f.uf}
			oninput={(e) => (f.uf = maskUf(e.currentTarget.value))}
			maxlength="2"
			placeholder="SP"
			class="{inputCls} uppercase"
		/>
	</label>
	<label class="block">
		{@render rotulo('Nº')}
		<input bind:value={f.numero} placeholder="000" class={inputCls} />
	</label>
</div>

<label class="mt-3 block">
	{@render rotulo('Complemento')}
	<input bind:value={f.complemento} placeholder="Apto / bloco (opcional)" class={inputCls} />
</label>
