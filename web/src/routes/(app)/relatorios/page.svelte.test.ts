import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

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
			{ date: '2026-06-01', total: 5, concluidos: 4, aberto: true },
			{ date: '2026-06-02', total: 3, concluidos: 2, aberto: true }
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

	// HOM-021 — o número aparecia sem a conta que o produz. Estas duas contas são as que a
	// gestão contesta, porque nenhuma das duas é adivinhável: a taxa de falta não divide pelo
	// total, e a ocupação é minutos, não sessões. A asserção é sobre a FÓRMULA, não sobre o
	// texto bonito: se a conta do servidor mudar e ninguém atualizar aqui, a tela passa a
	// explicar errado — que é pior do que não explicar.
	//
	// ACC-10 (doc 83) — a primeira entrega pendurou a explicação num `title=` de <div> e num
	// `aria-label` de <span> sem role (atributo PROIBIDO, que a tecnologia assistiva ignora).
	// Ou seja: existia só para quem usa mouse e vê a tela — no celular, onde não há hover, o
	// número voltava a ser um número sem conta. Agora é botão + diálogo, alcançável pelo dedo,
	// pelo Tab e pelo leitor de tela.
	describe('a fórmula de cada KPI está na tela', () => {
		it('cada um dos cinco KPIs tem um BOTÃO de explicação — não hover', () => {
			const { getAllByRole } = render(Page, { props: { data: data() as never } });
			const botoes = getAllByRole('button', { name: /como .+ é calculad/i });

			expect(botoes).toHaveLength(5);
			// A regressão do ACC-10 em si: se isto voltar a ser <span>, o toque e o teclado
			// perdem a explicação de novo — e nenhuma outra asserção deste arquivo perceberia.
			for (const b of botoes) expect(b.tagName).toBe('BUTTON');
		});

		it('taxa de falta abre o diálogo dizendo que o denominador são as sessões fechadas', async () => {
			const { getByRole } = render(Page, { props: { data: data() as never } });
			await fireEvent.click(getByRole('button', { name: /como taxa de falta é calculad/i }));

			const dialogo = getByRole('dialog');
			expect(dialogo).toHaveTextContent(/Faltas ÷ \(concluídos \+ faltas\)/i);
			expect(dialogo).toHaveTextContent(/já fecharam/i);
		});

		it('ocupação diz que é minuto, e mostra o par da divisão', async () => {
			const { getByRole } = render(Page, { props: { data: data() as never } });
			await fireEvent.click(getByRole('button', { name: /como ocupação é calculad/i }));

			// 300 e 540 vêm do `report()` — a explicação carrega os números reais do período,
			// senão vira prosa genérica que não ajuda a conferir.
			const dialogo = getByRole('dialog');
			expect(dialogo).toHaveTextContent(/Minutos ocupados ÷ minutos de expediente/i);
			expect(dialogo).toHaveTextContent(/300 de 540 min/);
		});

		it('o diálogo fecha, e só um abre por vez', async () => {
			const { getByRole, queryByRole } = render(Page, { props: { data: data() as never } });
			await fireEvent.click(getByRole('button', { name: /como atendimentos é calculad/i }));
			// A unidade do KPI virou PESSOA, não bloco (doc 88, A-1): numa turma cada participante
			// conta um. A fórmula diz isso porque é ela que torna o número contestável na mão.
			expect(getByRole('dialog')).toHaveTextContent(/cada participante conta um/i);

			await fireEvent.click(getByRole('button', { name: 'Fechar' }));
			expect(queryByRole('dialog')).not.toBeInTheDocument();
		});
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

	// Três desenhos, um cartão (doc 106): a barra vertical servia os três e desmontava nos
	// extremos — tijolos de 145px na semana, fios de 4,8px no trimestre.
	it('janela curta desenha uma linha por dia, com o nome do dia da semana', () => {
		const { getByText, queryByRole } = render(Page, { props: { data: data() as never } });

		expect(getByText('seg')).toBeInTheDocument(); // 01/06/2026 é uma segunda
		expect(getByText('01/06')).toBeInTheDocument();
		expect(queryByRole('table')).not.toBeInTheDocument();
	});

	it('janela longa troca as barras pelo calendário', () => {
		const mes = data({
			por_dia: Array.from({ length: 30 }, (_, i) => ({
				date: `2026-06-${String(i + 1).padStart(2, '0')}`,
				total: i,
				concluidos: i,
				aberto: true
			}))
		});
		const { getByRole } = render(Page, { props: { data: mes as never } });

		expect(getByRole('table')).toBeInTheDocument();
		expect(getByRole('rowheader', { name: 'seg' })).toBeInTheDocument();
		expect(getByRole('button', { name: '03/06: 2 atendimentos, 2 concluídos' })).toBeInTheDocument();
	});

	it('um dia só troca o gráfico para "Volume por profissional"', () => {
		const um = data({
			range: { from: '2026-06-17', to: '2026-06-17' },
			por_dia: [{ date: '2026-06-17', total: 4, concluidos: 3, aberto: true }]
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
