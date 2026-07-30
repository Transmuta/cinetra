<script lang="ts">
	// F5 (09 §7.4) — "quem mais está vendo este dia".
	//
	// Uma pilha de iniciais na barra da agenda. Discreta de propósito: é informação periférica
	// ("a Ana está com este dia aberto"), não um alerta — quem decide algo com ela é a pessoa,
	// e o que de fato impede duas remarcações simultâneas continua sendo a exclusion constraint
	// do agendamento, não este aviso.
	//
	// Só aparece com alguém: uma tela vazia não ganha um espaço reservado para o nada.
	import { initials } from '$lib/format';
	import { avatarColor, avatarStyle } from '$lib/avatar';

	let { nomes = [], max = 3 }: { nomes?: string[]; max?: number } = $props();

	const visiveis = $derived(nomes.slice(0, max));
	const excedente = $derived(Math.max(0, nomes.length - max));

	// A cor é derivada do NOME, não de `cor_indice`: quem está vendo o dia é um usuário, e
	// usuário não tem cor de avatar no domínio (isso é do profissional/paciente). Hash simples,
	// estável — a mesma pessoa fica com a mesma cor entre recarregamentos.
	function corDoNome(nome: string): string {
		let soma = 0;
		for (let i = 0; i < nome.length; i++) soma = (soma + nome.charCodeAt(i)) % 997;
		return avatarColor((soma % 7) + 1);
	}

	const rotulo = $derived(
		nomes.length === 1
			? `${nomes[0]} também está vendo este dia`
			: `${nomes.join(', ')} também estão vendo este dia`
	);
</script>

{#if nomes.length}
	<div class="flex items-center" title={rotulo} aria-label={rotulo}>
		{#each visiveis as nome (nome)}
			<span
				class="-ml-1.5 grid size-[22px] place-items-center rounded-full border-2 border-surface text-[9.5px] font-bold first:ml-0"
				style={avatarStyle(corDoNome(nome))}
			>
				{initials(nome)}
			</span>
		{/each}

		{#if excedente}
			<span
				class="-ml-1.5 grid size-[22px] place-items-center rounded-full border-2 border-surface bg-surface-2 text-[9.5px] font-bold text-muted"
			>
				+{excedente}
			</span>
		{/if}
	</div>
{/if}
