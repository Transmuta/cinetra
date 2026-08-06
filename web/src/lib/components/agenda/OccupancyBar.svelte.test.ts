import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';

import OccupancyBar from './OccupancyBar.svelte';

afterEach(cleanup);

const barra = () => screen.getByRole('meter');
const preenchimento = (c: HTMLElement) => (c.querySelector('[style*="width"]') as HTMLElement).style;

/**
 * Reusada por Semana e Mês, e estava sem teste (doc 93 §B-10). Ela existe justamente porque as
 * duas visões a desenhavam DIFERENTE — 45 fixo na semana, pico do mês no mês —, e A-D11 chamou
 * isso de "gráfico que mente": a mesma quantidade pintava diferente conforme a tela.
 */
describe('OccupancyBar', () => {
	it('é um medidor para a tecnologia assistiva, com o valor em porcento', () => {
		render(OccupancyBar, { rate: 0.42 });

		expect(barra()).toHaveAttribute('aria-valuenow', '42');
		expect(barra()).toHaveAccessibleName('Ocupação do dia');
	});

	it('o rótulo do dia entra no nome acessível quando vem', () => {
		render(OccupancyBar, { rate: 0.5, title: 'Quinta · 8 de 16 vagas' });

		expect(barra()).toHaveAccessibleName('Quinta · 8 de 16 vagas');
	});

	it('dia fechado (`null`) é 0% e tom `closed` — não some, fica vazio', () => {
		const { container } = render(OccupancyBar, { rate: null });

		expect(barra()).toHaveAttribute('data-tone', 'closed');
		expect(preenchimento(container).width).toBe('0%');
	});

	it('dia aberto e vazio é `empty`, que é outra coisa de fechado', () => {
		render(OccupancyBar, { rate: 0 });

		expect(barra()).toHaveAttribute('data-tone', 'empty');
	});

	/**
	 * Sem clamp no TOM: acima de 100% a barra fica vermelha. Sobrecarga é informação, e grampear
	 * esconderia exatamente o dia que precisa de atenção.
	 */
	it('acima da capacidade vira `over` — a largura satura, o tom não', () => {
		const { container } = render(OccupancyBar, { rate: 1.4 });

		expect(barra()).toHaveAttribute('data-tone', 'over');
		expect(preenchimento(container).width).toBe('100%');
		expect(barra()).toHaveAttribute('aria-valuenow', '140');
	});
});
