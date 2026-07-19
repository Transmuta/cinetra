import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import AgendaNav from './AgendaNav.svelte';

const base = { date: '2026-06-25', today: '2026-06-25', onDate: () => {} };

describe('AgendaNav', () => {
	it('mostra o rótulo contextual do dia', () => {
		render(AgendaNav, { props: { ...base, today: '2026-01-01' } });
		expect(screen.getByText('quinta-feira, 25 de junho')).toBeInTheDocument();
	});

	it('quando a data é hoje, o rótulo diz " · hoje"', () => {
		render(AgendaNav, { props: base });
		expect(screen.getByText(/· hoje/)).toBeInTheDocument();
	});

	it('a seta anterior recua um dia', async () => {
		const onDate = vi.fn();
		render(AgendaNav, { props: { ...base, onDate } });
		await userEvent.click(screen.getByRole('button', { name: 'Dia anterior' }));
		expect(onDate).toHaveBeenCalledWith('2026-06-24');
	});

	it('a seta seguinte avança um dia', async () => {
		const onDate = vi.fn();
		render(AgendaNav, { props: { ...base, onDate } });
		await userEvent.click(screen.getByRole('button', { name: 'Próximo dia' }));
		expect(onDate).toHaveBeenCalledWith('2026-06-26');
	});

	it('"Hoje" volta para o dia da clínica', async () => {
		const onDate = vi.fn();
		render(AgendaNav, { props: { ...base, date: '2026-08-10', onDate } });
		await userEvent.click(screen.getByRole('button', { name: 'Hoje' }));
		expect(onDate).toHaveBeenCalledWith('2026-06-25');
	});

	it('"Hoje" fica destacado quando já se está nele', () => {
		render(AgendaNav, { props: base });
		expect(screen.getByRole('button', { name: 'Hoje' })).toHaveAttribute('aria-current', 'date');
	});

	// Entrega 1 é só a visão Dia (A1). Os outros três existem na barra para não mentir sobre
	// o modelo de navegação, mas ficam desabilitados COM explicação — botão morto sem motivo
	// é pior que botão ausente.
	it('só "Dia" funciona; Semana, Mês e Lista ficam desabilitados com explicação', () => {
		render(AgendaNav, { props: base });

		expect(screen.getByRole('button', { name: 'Dia' })).toBeEnabled();
		for (const nome of ['Semana', 'Mês', 'Lista']) {
			const b = screen.getByRole('button', { name: nome });
			expect(b).toBeDisabled();
			expect(b.getAttribute('title')).toMatch(/em breve|próxima entrega/i);
		}
	});

	it('"Dia" está marcado como a visão atual', () => {
		render(AgendaNav, { props: base });
		expect(screen.getByRole('button', { name: 'Dia' })).toHaveAttribute('aria-current', 'page');
	});
});
