import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';

import Page from './+page.svelte';
import type { ReportsData } from '$lib/reports';

const profs = [
	{ id: 'p1', nome: 'Dra. Bea', cor_indice: 1 },
	{ id: 'p2', nome: 'Dr. Bruno', cor_indice: 2 }
];
const types = [{ id: 't1', nome: 'Fisioterapia', cor: '#0FB5A6' }];

function report(over: Partial<ReportsData> = {}): ReportsData {
	return {
		range: { from: '2026-06-01', to: '2026-06-30' },
		totals: {
			atendimentos: 10,
			concluidos: 6,
			faltas: 2,
			cancelados: 1,
			futuros: 2,
			taxa_falta: 25,
			ocupacao: 62,
			ocupado_minutos: 300,
			capacidade_minutos: 540,
			dias_uteis: 22,
			pico: { date: '2026-06-12', total: 5 }
		},
		por_dia: [
			{ date: '2026-06-01', total: 5, concluidos: 4 },
			{ date: '2026-06-02', total: 3, concluidos: 2 }
		],
		por_tipo: [{ appointment_type_id: 't1', total: 8 }],
		por_profissional: [
			{ professional_id: 'p1', total: 7, concluidos: 5, faltas: 1, taxa_falta: 17 },
			{ professional_id: 'p2', total: 3, concluidos: 1, faltas: 1, taxa_falta: 50 }
		],
		professionals: profs,
		appointment_types: types,
		agora: '2026-06-17T12:00:00Z',
		timezone: 'America/Sao_Paulo',
		...over
	};
}

function data(over: Partial<ReportsData> = {}, period = 'mes', prof = 'todos') {
	return { report: report(over), period, prof };
}

describe('Relatórios — render', () => {
	it('mostra os KPIs, o pico e a taxa de falta', () => {
		const { getByText } = render(Page, { props: { data: data() as never } });

		expect(getByText('Atendimentos')).toBeInTheDocument();
		expect(getByText('Taxa de falta')).toBeInTheDocument();
		expect(getByText('25%')).toBeInTheDocument(); // taxa de falta
		expect(getByText('62%')).toBeInTheDocument(); // ocupação
		// Pico no cabeçalho (janela de vários dias).
		expect(getByText('12/06')).toBeInTheDocument();
	});

	it('janela com vários dias mostra "Volume por dia" e a tabela por profissional', () => {
		const { getByText } = render(Page, { props: { data: data() as never } });

		expect(getByText('Volume por dia')).toBeInTheDocument();
		expect(getByText('Desempenho por profissional')).toBeInTheDocument();
		expect(getByText('Bea')).toBeInTheDocument();
		expect(getByText('Bruno')).toBeInTheDocument();
		// A barra por tipo traz o nome do tipo.
		expect(getByText('Fisioterapia')).toBeInTheDocument();
	});

	it('um dia só troca o gráfico para "Volume por profissional"', () => {
		const um = data({
			range: { from: '2026-06-17', to: '2026-06-17' },
			por_dia: [{ date: '2026-06-17', total: 4, concluidos: 3 }]
		});
		const { getByText, queryByText } = render(Page, { props: { data: um as never } });

		expect(getByText('Volume por profissional')).toBeInTheDocument();
		expect(queryByText('Volume por dia')).not.toBeInTheDocument();
	});

	it('sem tipos no período mostra o estado vazio', () => {
		const vazio = data({ por_tipo: [] });
		const { getByText } = render(Page, { props: { data: vazio as never } });
		expect(getByText('Sem dados no período.')).toBeInTheDocument();
	});
});
