import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, within } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import MonthView from './MonthView.svelte';
import { dayCountFixture, agendaProfessionalFixture } from '$lib/testing/fixtures';

const P1 = agendaProfessionalFixture({ id: 'p1' });

// Julho de 2026 começa numa quarta e tem 31 dias: 5 linhas (35 células).
const base = {
	date: '2026-07-15',
	today: '2026-07-15',
	days: [dayCountFixture('2026-07-15')],
	professionals: [P1],
	onPick: () => {},
	onShowAll: () => {}
};

const celula = (dia: string) =>
	screen.getAllByRole('button').find((b) => b.getAttribute('aria-label')?.startsWith(dia))!;

describe('MonthView', () => {
	it('desenha semanas inteiras a partir de domingo', () => {
		render(MonthView, { props: base });
		expect(screen.getAllByRole('button')).toHaveLength(35);
		expect(screen.getByText('Dom')).toBeInTheDocument();
		expect(screen.getByText('Sáb')).toBeInTheDocument();
	});

	it('conta o dia e desenha a barra pela ocupação real', () => {
		render(MonthView, { props: base });
		const c = celula('2026-07-15');
		expect(within(c).getByText('3 agend.')).toBeInTheDocument();
		expect(within(c).getByRole('meter')).toHaveAttribute('aria-valuenow', '50');
	});

	// Uma barra sempre em zero e um rótulo sem número, repetidos 20 vezes por mês, são ruído
	// que não informa — e foi assim que a primeira versão saiu.
	it('dia aberto e vazio não desenha barra nem rótulo', () => {
		render(MonthView, {
			props: {
				...base,
				days: [dayCountFixture('2026-07-15', [{ total: 0, ocupado_minutos: 0 }])]
			}
		});
		const c = celula('2026-07-15');
		expect(within(c).queryByRole('meter')).not.toBeInTheDocument();
		expect(within(c).queryByText(/agend\./)).not.toBeInTheDocument();
		expect(within(c).queryByText('fechado')).not.toBeInTheDocument();
	});

	// A janela pedida ao servidor é o MÊS (teto de 31 dias); a grade chega a 42 células. As
	// de fora não têm contagem — e não podem inventar uma.
	it('célula de fora do mês não afirma número nenhum', () => {
		render(MonthView, { props: base });
		const c = celula('2026-06-30');
		expect(within(c).queryByRole('meter')).not.toBeInTheDocument();
		expect(c).toHaveAttribute('aria-label', '2026-06-30');
	});

	it('dia do mês sem expediente diz "fechado", e não desenha barra', () => {
		render(MonthView, {
			props: {
				...base,
				days: [
					dayCountFixture('2026-07-15', [
						{ total: 0, ocupado_minutos: 0, capacidade_minutos: 0 }
					])
				]
			}
		});
		const c = celula('2026-07-15');
		expect(within(c).getByText('fechado')).toBeInTheDocument();
		expect(within(c).queryByRole('meter')).not.toBeInTheDocument();
	});

	it('marca hoje', () => {
		render(MonthView, { props: base });
		expect(celula('2026-07-15')).toHaveAttribute('aria-current', 'date');
	});

	// Mesmo bug da Semana: todos ocultos pintava o mês inteiro de "fechado", afirmando que a
	// clínica não abre quando quem sumiu foram os profissionais.
	it('todos ocultos → estado vazio, não um mês inteiro "fechado"', () => {
		render(MonthView, { props: { ...base, hidden: ['p1'] } });
		expect(screen.getByText('Nenhum profissional em exibição')).toBeInTheDocument();
		expect(screen.queryByText('fechado')).not.toBeInTheDocument();
	});

	it('clicar numa célula abre aquele dia', async () => {
		const onPick = vi.fn();
		render(MonthView, { props: { ...base, onPick } });
		await userEvent.click(celula('2026-07-20'));
		expect(onPick).toHaveBeenCalledWith('2026-07-20');
	});

	it('fevereiro de 2026 fecha em 4 linhas exatas', () => {
		render(MonthView, { props: { ...base, date: '2026-02-10', days: [] } });
		expect(screen.getAllByRole('button')).toHaveLength(28);
	});
});
