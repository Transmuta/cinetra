import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup, fireEvent } from '@testing-library/svelte';
import VolumeCalendario from './VolumeCalendario.svelte';
import { weekdayIndex, type DayPoint } from '$lib/reports';
import { shiftDate } from '$lib/agenda';

// Domingo fechado (o seed da clínica), como o servidor devolve.
function janela(from: string, dias: number, totals: Record<string, number> = {}): DayPoint[] {
	return Array.from({ length: dias }, (_, i) => {
		const date = shiftDate(from, i);
		const total = totals[date] ?? 0;
		return { date, total, concluidos: Math.floor(total / 2), aberto: weekdayIndex(date) !== 6 };
	});
}

// 01/06/2026 é uma segunda; 28 dias fecham quatro semanas cheias.
const JUNHO = janela('2026-06-01', 28, { '2026-06-03': 8, '2026-06-08': 4, '2026-06-17': 1 });

afterEach(cleanup);

function montar(porDia = JUNHO, today = '2026-06-17') {
	return render(VolumeCalendario, { props: { porDia, today } });
}

describe('VolumeCalendario', () => {
	it('desenha uma coluna por semana e uma linha por dia da semana', () => {
		const { getByRole, getAllByRole } = montar();

		// Quatro semanas + o cabeçalho de mês, e as linhas de seg a sáb (domingo fechado sai).
		expect(getAllByRole('row')).toHaveLength(7); // 1 cabeçalho + 6 dias da semana
		expect(getByRole('rowheader', { name: 'seg' })).toBeInTheDocument();
		expect(getByRole('rowheader', { name: 'sáb' })).toBeInTheDocument();
		expect(() => getByRole('rowheader', { name: 'dom' })).toThrow();
		expect(getByRole('columnheader', { name: 'jun' })).toBeInTheDocument();
	});

	// O número saía só no `title=`, que no celular não existe — o mesmo ACC-10 que os KPIs desta
	// tela já tinham corrigido.
	it('cada dia leva o número no nome acessível, não num tooltip de mouse', () => {
		const { getByRole } = montar();

		expect(
			getByRole('button', { name: '03/06: 8 atendimentos, 4 concluídos' })
		).toBeInTheDocument();
		expect(getByRole('button', { name: '02/06: 0 atendimentos, 0 concluídos' })).toBeInTheDocument();
	});

	it('dia fechado se anuncia como fechado, e não como dia sem atendimento', () => {
		// 07/06 é domingo; entra como linha porque tem atendimento, mas segue fechado.
		const { getByRole } = montar(janela('2026-06-01', 28, { '2026-06-07': 2 }));
		expect(getByRole('rowheader', { name: 'dom' })).toBeInTheDocument();
		expect(getByRole('button', { name: '14/06: clínica fechada' })).toBeInTheDocument();
	});

	it('a média por dia da semana fica na coluna da direita', () => {
		const { getByRole, getAllByRole } = montar();

		expect(getByRole('columnheader', { name: 'média por dia' })).toBeInTheDocument();
		// Linha de quarta: 8 (03/06), 1 (17/06) e dois zeros em quatro dias abertos → 2.3.
		const quarta = getAllByRole('row')[3];
		expect(quarta).toHaveTextContent('2.3');
	});

	it('marca o hoje da clínica', () => {
		const { getByRole } = montar();
		const hoje = getByRole('button', { name: '17/06: 1 atendimento, 0 concluídos' });
		expect(hoje).toHaveAttribute('aria-current', 'date');
	});

	// Uma parada de Tab para a grade inteira: 90 células focáveis seriam 90 paradas.
	it('só a célula do foco é tabulável; as setas movem a seleção', async () => {
		const { getAllByRole } = montar();

		const celulas = getAllByRole('button');
		expect(celulas.filter((c) => c.getAttribute('tabindex') === '0')).toHaveLength(1);
		expect(celulas[0]).toHaveAttribute('tabindex', '0'); // 01/06, primeira em ordem de leitura

		await fireEvent.keyDown(celulas[0], { key: 'ArrowRight' });
		expect(celulas[0]).toHaveAttribute('tabindex', '-1');
		expect(getAllByRole('button').find((c) => c.getAttribute('tabindex') === '0')).toHaveAccessibleName(
			'08/06: 4 atendimentos, 2 concluídos'
		);
	});

	it('o detalhe do dia aparece ao passar o mouse, e volta para a legenda ao sair', async () => {
		const { getByRole, getByTestId, queryByTestId } = montar();
		const celula = getByRole('button', { name: '03/06: 8 atendimentos, 4 concluídos' });

		expect(getByTestId('volume-legenda')).toBeInTheDocument();

		await fireEvent.mouseEnter(celula);
		expect(getByTestId('volume-detalhe')).toHaveTextContent('03/06 · 8 atendimentos, 4 concluídos');
		expect(queryByTestId('volume-legenda')).not.toBeInTheDocument();

		await fireEvent.mouseLeave(celula);
		expect(getByTestId('volume-legenda')).toBeInTheDocument();
	});

	// O teclado tem de chegar ao mesmo número que o mouse: sem isso a grade volta a ser um
	// gráfico só-de-hover, que é o defeito que ela veio corrigir.
	it('o foco pelo teclado mostra o mesmo detalhe do hover', async () => {
		const { getByRole, getByTestId } = montar();

		await fireEvent.focus(getByRole('button', { name: '03/06: 8 atendimentos, 4 concluídos' }));
		expect(getByTestId('volume-detalhe')).toHaveTextContent('03/06 · 8 atendimentos, 4 concluídos');
	});

	it('janela que começa no meio da semana deixa a célula ausente vazia, não fechada', () => {
		// Começa numa quarta: seg e ter da primeira coluna não existem na janela.
		const { getAllByRole } = montar(janela('2026-06-17', 19), '2026-06-17');
		const primeira = getAllByRole('button')[0];
		expect(primeira).toHaveAccessibleName('22/06: 0 atendimentos, 0 concluídos');
	});

	it('período sem nenhum dia não quebra a tabela', () => {
		const { queryAllByRole } = montar([]);
		expect(queryAllByRole('button')).toHaveLength(0);
	});
});
