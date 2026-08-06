<script lang="ts">
	// A barra de ocupação de um dia — a fórmula única de A-D12, desenhada.
	//
	// Existe como componente porque Semana e Mês a desenham igual, e foi justamente a
	// divergência entre as duas (45 fixo na semana, pico do mês no mês) que A-D11 chamou de
	// "gráfico que mente": a mesma quantidade pintava diferente em cada visão.
	//
	// Sem clamp: acima de 100% a barra enche e fica vermelha. Sobrecarga é informação, e
	// grampear esconde exatamente o dia que precisa de atenção.
	import { occupancyTone } from '$lib/agenda-views';

	let { rate, title = undefined }: { rate: number | null; title?: string } = $props();

	const tone = $derived(occupancyTone(rate));

	const COR: Record<string, string> = {
		closed: 'var(--color-edge)',
		empty: 'var(--color-edge)',
		normal: 'var(--color-accent)',
		over: 'var(--color-danger)'
	};

	const largura = $derived(rate === null ? 0 : Math.min(100, rate * 100));
</script>

<div
	class="h-1 w-full overflow-hidden rounded-controle bg-surface-2"
	data-tone={tone}
	role="meter"
	aria-valuemin={0}
	aria-valuenow={Math.round((rate ?? 0) * 100)}
	aria-label={title ?? 'Ocupação do dia'}
>
	<div class="h-full rounded-controle" style="width:{largura}%; background:{COR[tone]}"></div>
</div>
