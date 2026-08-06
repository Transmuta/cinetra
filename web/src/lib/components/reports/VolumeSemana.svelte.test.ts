import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup } from '@testing-library/svelte';
import VolumeSemana from './VolumeSemana.svelte';
import type { DayPoint } from '$lib/reports';

// Segunda a domingo de uma semana comum; domingo fechado, como o seed da clínica.
const SEMANA: DayPoint[] = [
	{ date: '2026-06-15', total: 12, concluidos: 10, aberto: true },
	{ date: '2026-06-16', total: 6, concluidos: 5, aberto: true },
	{ date: '2026-06-17', total: 0, concluidos: 0, aberto: true },
	{ date: '2026-06-18', total: 9, concluidos: 7, aberto: true },
	{ date: '2026-06-19', total: 4, concluidos: 4, aberto: true },
	{ date: '2026-06-20', total: 3, concluidos: 3, aberto: true },
	{ date: '2026-06-21', total: 0, concluidos: 0, aberto: false }
];

afterEach(cleanup);

describe('VolumeSemana', () => {
	it('nomeia o dia da semana junto da data — o número sozinho não se lê', () => {
		const { getByText } = render(VolumeSemana, {
			props: { porDia: SEMANA, today: '2026-06-17' }
		});

		expect(getByText('seg')).toBeInTheDocument();
		expect(getByText('15/06')).toBeInTheDocument();
		expect(getByText('sáb')).toBeInTheDocument();
	});

	// O defeito que a barra vertical carregava: o total só existia no `title=`, hover de mouse.
	it('o total e os concluídos ficam em texto, não em tooltip', () => {
		const { getByText } = render(VolumeSemana, {
			props: { porDia: SEMANA, today: '2026-06-17' }
		});

		expect(getByText('12')).toBeInTheDocument();
		expect(getByText('10 concl.')).toBeInTheDocument();
	});

	it('domingo fechado se anuncia fechado; a quarta vazia mostra zero', () => {
		const { getByText, getAllByText } = render(VolumeSemana, {
			props: { porDia: SEMANA, today: '2026-06-17' }
		});

		expect(getByText('clínica fechada')).toBeInTheDocument();
		// A quarta está ABERTA e sem ninguém — o zero é dela, e é um dado, não um buraco.
		expect(getAllByText('0').length).toBeGreaterThan(0);
	});

	it('marca o hoje da clínica na linha', () => {
		const { container } = render(VolumeSemana, {
			props: { porDia: SEMANA, today: '2026-06-17' }
		});

		const hoje = container.querySelector('[aria-current="date"]');
		expect(hoje).toHaveTextContent('qua');
		expect(hoje).toHaveTextContent('17/06');
	});

	it('semana inteira sem atendimento não divide por zero', () => {
		const zerada = SEMANA.map((d) => ({ ...d, total: 0, concluidos: 0 }));
		const { getAllByText } = render(VolumeSemana, { props: { porDia: zerada, today: '' } });
		expect(getAllByText('0')).toHaveLength(6); // as seis linhas abertas; o domingo diz "—"
	});
});
