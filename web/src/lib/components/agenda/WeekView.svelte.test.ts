import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, within } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import WeekView from './WeekView.svelte';
import { dayCountFixture, agendaProfessionalFixture } from '$lib/testing/fixtures';

// Semana de 2026-07-20 (segunda) a 2026-07-26 (domingo).
const SEG = '2026-07-20';
const DOM = '2026-07-26';

const P1 = agendaProfessionalFixture({ id: 'p1' });
const P2 = agendaProfessionalFixture({ id: 'p2', nome: 'Dr. Dois' });

const base = {
	date: SEG,
	today: SEG,
	days: [dayCountFixture(SEG)],
	professionals: [P1],
	onPick: () => {},
	onShowAll: () => {}
};

describe('WeekView', () => {
	// A-D11: o protótipo mostrava seg–sáb e nunca domingo. Clínica que abre domingo existe.
	it('mostra 7 cartões, de segunda a domingo', () => {
		render(WeekView, { props: base });
		expect(screen.getAllByRole('button')).toHaveLength(7);
		expect(screen.getByText('20')).toBeInTheDocument();
		expect(screen.getByText('26')).toBeInTheDocument();
	});

	it('conta os agendamentos do dia', () => {
		render(WeekView, { props: base });
		expect(screen.getByText('3 agend.')).toBeInTheDocument();
	});

	// A grade sai do calendário, não da resposta: dia sem linha ainda é dia da semana.
	it('dia ausente na resposta continua tendo cartão', () => {
		render(WeekView, { props: { ...base, days: [] } });
		expect(screen.getAllByRole('button')).toHaveLength(7);
	});

	it('dia sem expediente diz "Sem expediente", não "0 agend."', () => {
		render(WeekView, {
			props: {
				...base,
				days: [dayCountFixture(SEG, [{ total: 0, ocupado_minutos: 0, capacidade_minutos: 0 }])]
			}
		});
		const cartao = screen.getByText('20').closest('button')!;
		expect(within(cartao).getByText('Sem expediente')).toBeInTheDocument();
		expect(within(cartao).queryByText('0 agend.')).not.toBeInTheDocument();
	});

	// A-D12: minutos ocupados ÷ expediente real. 270/540 = 50%.
	it('a barra é ocupação real, não uma constante mágica', () => {
		render(WeekView, { props: base });
		const barra = screen.getByRole('meter', { name: /Ocupação de 2026-07-20/ });
		expect(barra).toHaveAttribute('aria-valuenow', '50');
		expect(barra).toHaveAttribute('data-tone', 'normal');
	});

	it('acima de 100% a barra fica em sobrecarga, sem grampear', () => {
		render(WeekView, {
			props: { ...base, days: [dayCountFixture(SEG, [{ ocupado_minutos: 810 }])] }
		});
		const barra = screen.getByRole('meter', { name: /Ocupação de 2026-07-20/ });
		expect(barra).toHaveAttribute('aria-valuenow', '150');
		expect(barra).toHaveAttribute('data-tone', 'over');
	});

	// B-D2: ocultar na sidebar tem de mexer na barra, senão a Semana discorda do Dia.
	it('profissional oculto sai do numerador e do denominador', () => {
		render(WeekView, {
			props: {
				...base,
				professionals: [P1, P2],
				days: [dayCountFixture(SEG, [{ professional_id: 'p1' }, { professional_id: 'p2' }])],
				hidden: ['p2']
			}
		});

		const cartao = screen.getByText('20').closest('button')!;
		// Sobra só o p1: 3 agendamentos e 270/540, não 6 e 540/1080.
		expect(within(cartao).getByText('3 agend.')).toBeInTheDocument();
		expect(within(cartao).getByRole('meter')).toHaveAttribute('aria-valuenow', '50');
	});

	// O bug que o bate-volta pegou no navegador: com TODOS ocultos, a matemática dá capacidade
	// zero e o cartão dizia "Sem expediente" — afirmando que a clínica não abre, quando quem
	// sumiu foram os profissionais. É o estado que a visão Dia já tinha (doc 25 §6).
	it('todos ocultos → estado vazio, não "Sem expediente"', () => {
		render(WeekView, { props: { ...base, hidden: ['p1'] } });

		expect(screen.getByText('Nenhum profissional em exibição')).toBeInTheDocument();
		expect(screen.queryByText('Sem expediente')).not.toBeInTheDocument();
	});

	it('"Mostrar todos" devolve a semana', async () => {
		const onShowAll = vi.fn();
		render(WeekView, { props: { ...base, hidden: ['p1'], onShowAll } });
		await userEvent.click(screen.getByRole('button', { name: 'Mostrar todos' }));
		expect(onShowAll).toHaveBeenCalled();
	});

	it('marca hoje', () => {
		render(WeekView, { props: { ...base, today: DOM } });
		expect(screen.getByText('hoje')).toBeInTheDocument();
	});

	it('clicar num cartão abre aquele dia', async () => {
		const onPick = vi.fn();
		render(WeekView, { props: { ...base, onPick } });
		await userEvent.click(screen.getByText('22').closest('button')!);
		expect(onPick).toHaveBeenCalledWith('2026-07-22');
	});
});
