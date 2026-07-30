import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import DayViewers from './DayViewers.svelte';

describe('DayViewers (F5 — quem está vendo este dia)', () => {
	it('sem ninguém, não desenha nada — a barra não ganha espaço reservado para o vazio', () => {
		const { container } = render(DayViewers, { props: { nomes: [] } });
		expect(container.textContent?.trim()).toBe('');
	});

	it('mostra as iniciais de quem está vendo', () => {
		render(DayViewers, { props: { nomes: ['Ana Lima', 'Bruno Sousa'] } });

		expect(screen.getByText('AL')).toBeInTheDocument();
		expect(screen.getByText('BS')).toBeInTheDocument();
	});

	it('acima do teto, corta e conta o resto', () => {
		render(DayViewers, {
			props: { nomes: ['Ana Lima', 'Bruno Sousa', 'Caio Reis', 'Dora Melo'], max: 3 }
		});

		expect(screen.getByText('+1')).toBeInTheDocument();
		expect(screen.queryByText('DM')).not.toBeInTheDocument();
	});

	it('o rótulo acessível nomeia todo mundo, mesmo quem foi cortado da pilha', () => {
		render(DayViewers, { props: { nomes: ['Ana Lima', 'Bruno Sousa', 'Caio Reis', 'Dora Melo'] } });

		expect(
			screen.getByLabelText('Ana Lima, Bruno Sousa, Caio Reis, Dora Melo também estão vendo este dia')
		).toBeInTheDocument();
	});

	it('com uma pessoa só, o texto fica no singular', () => {
		render(DayViewers, { props: { nomes: ['Ana Lima'] } });
		expect(screen.getByLabelText('Ana Lima também está vendo este dia')).toBeInTheDocument();
	});
});
