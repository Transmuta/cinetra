<script lang="ts">
	// "Nenhum profissional em exibição" — o estado que o doc 25 §6 avisa ser fácil de esquecer,
	// porque só aparece por AÇÃO do usuário (ocultar todo mundo na barra lateral).
	//
	// Vive num componente só porque as quatro visões precisam dele e cada uma degradava para
	// uma frase FALSA diferente quando ele faltava: a Semana dizia "Sem expediente" (a clínica
	// abre; quem sumiu foram os profissionais), o Mês desenhava células vazias, e a Lista dizia
	// "Nenhum agendamento neste dia" havendo agendamentos — apenas filtrados.
	import EyeOff from '@lucide/svelte/icons/eye-off';

	let { onShowAll }: { onShowAll: () => void } = $props();
</script>

<div
	class="flex h-full flex-col items-center justify-center gap-2.5 bg-canvas p-6 text-center text-faint"
>
	<EyeOff size={26} />
	<div class="text-[13.5px] font-semibold text-muted">Nenhum profissional em exibição</div>
	<div class="text-[12.5px]">
		Ative ao menos um profissional na barra lateral para ver a agenda.
	</div>
	<button
		type="button"
		onclick={onShowAll}
		class="mt-1 rounded-lg bg-primary px-3.5 py-2 text-[13px] font-semibold text-on-primary hover:opacity-90"
	>
		Mostrar todos
	</button>
</div>
