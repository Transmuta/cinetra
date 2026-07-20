import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import AgendaNav from './AgendaNav.svelte';

const base = {
	date: '2026-06-25',
	today: '2026-06-25',
	onDate: () => {},
	onView: () => {}
};

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

	// Entrega 2: as quatro visões passam a existir de verdade.
	it('as quatro visões estão disponíveis', () => {
		render(AgendaNav, { props: base });
		for (const nome of ['Dia', 'Semana', 'Mês', 'Lista']) {
			expect(screen.getByRole('button', { name: nome })).toBeEnabled();
		}
	});

	it('"Dia" está marcado como a visão atual', () => {
		render(AgendaNav, { props: base });
		expect(screen.getByRole('button', { name: 'Dia' })).toHaveAttribute('aria-current', 'page');
	});

	it('trocar de visão avisa a rota', async () => {
		const onView = vi.fn();
		render(AgendaNav, { props: { ...base, onView } });
		await userEvent.click(screen.getByRole('button', { name: 'Semana' }));
		expect(onView).toHaveBeenCalledWith('semana');
	});

	it('a visão atual é a que vem por prop, não um estado interno', () => {
		render(AgendaNav, { props: { ...base, view: 'mes' } });
		expect(screen.getByRole('button', { name: 'Mês' })).toHaveAttribute('aria-current', 'page');
		expect(screen.getByRole('button', { name: 'Dia' })).not.toHaveAttribute('aria-current');
	});
});

// O passo da seta é o da VISÃO — e o rótulo acompanha, senão quem navega por leitor de tela
// ouve "Dia anterior" numa agenda mensal.
describe('AgendaNav — passo por visão', () => {
	it.each([
		['semana', 'Semana anterior', 'Próximo semana', '2026-06-18', '2026-07-02'],
		['mes', 'Mês anterior', 'Próximo mês', '2026-05-25', '2026-07-25'],
		['lista', 'Dia anterior', 'Próximo dia', '2026-06-24', '2026-06-26']
	] as const)('%s anda o passo certo', async (view, anterior, proximo, antes, depois) => {
		const onDate = vi.fn();
		render(AgendaNav, { props: { ...base, view, onDate } });

		await userEvent.click(screen.getByRole('button', { name: anterior }));
		expect(onDate).toHaveBeenCalledWith(antes);

		await userEvent.click(screen.getByRole('button', { name: proximo }));
		expect(onDate).toHaveBeenCalledWith(depois);
	});

	// As duas setas leem o MESMO registro. Quando o "anterior" reconstruía o mapa por ternário,
	// uma visão nova deixava o "próximo" certo e o "anterior" caindo calado em "Dia anterior".
	it('as duas setas concordam sobre o passo, em todas as visões', () => {
		for (const [view, curto, capitalizado] of [
			['dia', 'dia', 'Dia'],
			['lista', 'dia', 'Dia'],
			['semana', 'semana', 'Semana'],
			['mes', 'mês', 'Mês']
		] as const) {
			const { unmount } = render(AgendaNav, { props: { ...base, view } });
			expect(screen.getByRole('button', { name: `${capitalizado} anterior` })).toBeInTheDocument();
			expect(screen.getByRole('button', { name: `Próximo ${curto}` })).toBeInTheDocument();
			unmount();
		}
	});

	it('o rótulo contextual muda com a visão', () => {
		const { unmount } = render(AgendaNav, {
			props: { ...base, view: 'semana', today: '2020-01-01' }
		});
		expect(screen.getByText('22 jun. – 28 jun.')).toBeInTheDocument();
		unmount();

		render(AgendaNav, { props: { ...base, view: 'mes', today: '2020-01-01' } });
		expect(screen.getByText('junho de 2026')).toBeInTheDocument();
	});
});
