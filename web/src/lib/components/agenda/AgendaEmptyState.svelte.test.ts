import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

import AgendaEmptyState from './AgendaEmptyState.svelte';

afterEach(cleanup);

/**
 * Reusado pelas quatro visões da agenda e estava sem teste (doc 93 §B-10).
 *
 * O que ele existe para impedir é o vazio que MENTE: sem ele, cada visão degradava para uma frase
 * falsa diferente — a Semana dizia "Sem expediente" (a clínica abre; quem sumiu foram os
 * profissionais), o Mês desenhava células vazias, e a Lista dizia "Nenhum agendamento neste dia"
 * havendo agendamentos, apenas filtrados. Doc 25 §6.
 */
describe('AgendaEmptyState', () => {
	it('diz que o filtro é a causa — não que a agenda está vazia', () => {
		render(AgendaEmptyState, { onShowAll: vi.fn() });

		expect(screen.getByText('Nenhum profissional em exibição')).toBeInTheDocument();
		expect(screen.getByText(/barra lateral/i)).toBeInTheDocument();
	});

	it('oferece a saída — constatar sem dar o caminho de volta é meio conserto', async () => {
		const onShowAll = vi.fn();
		render(AgendaEmptyState, { onShowAll });

		await userEvent.click(screen.getByRole('button', { name: 'Mostrar todos' }));

		expect(onShowAll).toHaveBeenCalledOnce();
	});

	/** Ele preenche a área da grade, não é um cartão solto no meio da página. */
	it('ocupa a altura toda sobre o canvas', () => {
		const { container } = render(AgendaEmptyState, { onShowAll: vi.fn() });

		expect(container.firstElementChild?.className).toContain('h-full');
	});
});
