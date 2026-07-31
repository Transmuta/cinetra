<script lang="ts">
	// "Nenhum profissional em exibição" — o estado que o doc 25 §6 avisa ser fácil de esquecer,
	// porque só aparece por AÇÃO do usuário (ocultar todo mundo na barra lateral).
	//
	// Vive num componente só porque as quatro visões precisam dele e cada uma degradava para
	// uma frase FALSA diferente quando ele faltava: a Semana dizia "Sem expediente" (a clínica
	// abre; quem sumiu foram os profissionais), o Mês desenhava células vazias, e a Lista dizia
	// "Nenhum agendamento neste dia" havendo agendamentos — apenas filtrados.
	//
	// A casca agora é o `EstadoVazio`, que carrega essa mesma lição para as outras quatro telas
	// que a repetiam com geometria própria (doc 94 §2.4). O que sobra aqui é o que é da AGENDA: o
	// texto, a saída ("Mostrar todos") e o `h-full` sobre o canvas — este vazio preenche a área da
	// grade, não é um cartão no meio de uma página.
	import EyeOff from '@lucide/svelte/icons/eye-off';
	import EstadoVazio from '$lib/components/EstadoVazio.svelte';

	let { onShowAll }: { onShowAll: () => void } = $props();
</script>

<EstadoVazio
	icone={EyeOff}
	titulo="Nenhum profissional em exibição"
	variante="inline"
	class="h-full bg-canvas"
>
	{#snippet descricao()}
		Ative ao menos um profissional na barra lateral para ver a agenda.
	{/snippet}

	{#snippet acao()}
		<button
			type="button"
			onclick={onShowAll}
			class="rounded-controle bg-primary px-3.5 py-2 text-corpo font-semibold text-on-primary hover:bg-primary-hover"
		>
			Mostrar todos
		</button>
	{/snippet}
</EstadoVazio>
