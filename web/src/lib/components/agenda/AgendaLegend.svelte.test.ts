import { describe, it, expect, beforeEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import AgendaLegend from './AgendaLegend.svelte';

describe('AgendaLegend', () => {
	beforeEach(() => localStorage.clear());

	// HOM-002: a cor não tinha legenda em lugar nenhum (`grep -i legenda` no web = zero).
	it('nomeia os seis status', async () => {
		render(AgendaLegend);
		for (const rotulo of [
			'Agendado',
			'Confirmado',
			'Em atendimento',
			'Concluído',
			'Faltou',
			'Cancelado'
		]) {
			expect(await screen.findByText(rotulo)).toBeInTheDocument();
		}
	});

	// §9.3 do doc 37: a proposta do relatório enfileirava "Ação necessária" junto dos status,
	// cometendo o defeito que ela diagnostica — pendência é ortogonal, não é um sétimo status.
	it('separa o que aconteceu do que exige atenção', () => {
		render(AgendaLegend);
		expect(screen.getByText('O que aconteceu')).toBeInTheDocument();
		expect(screen.getByText('Exige atenção')).toBeInTheDocument();
	});

	it('explica os marcadores que a proposta esquecera', () => {
		render(AgendaLegend);
		expect(screen.getByText('Conflito de horário')).toBeInTheDocument();
		expect(screen.getByText('Encaixe')).toBeInTheDocument();
		expect(screen.getByText('Registrar status')).toBeInTheDocument();
	});

	// Bate-volta: a fatia criou um sinal que a legenda não explicava — o badge de composição da
	// turma ("3 de 4 concluídas", D13) e o ponto NEUTRO que o acompanha quando a turma é mista.
	// Esse ponto é o mesmo `--color-muted` de "Agendado" e "Cancelado": três estados, uma cor,
	// e a legenda descrevendo só dois. É o HOM-002 reaparecendo dentro da própria correção dele.
	it('explica a composição da turma, que é o sinal que a fatia introduziu', () => {
		render(AgendaLegend);
		expect(screen.getByText('3 de 4 concluídas')).toBeInTheDocument();
		expect(screen.getByText(/Quantos vieram/)).toBeInTheDocument();
	});

	// O card ganhou um sinal que vem de FORA do sistema (doc 52 §5) — o paciente clicando no link.
	// Sinal no card sem linha na legenda é a pergunta "e essa estrelinha?", que é exatamente o que
	// esta legenda existe para não deixar acontecer.
	it('explica os dois sinais da resposta do paciente', () => {
		render(AgendaLegend);

		expect(screen.getByText('O paciente respondeu')).toBeInTheDocument();
		expect(screen.getByText('Confirmou presença')).toBeInTheDocument();
		expect(screen.getByText('Pediu para remarcar')).toBeInTheDocument();
	});

	// D3: aberta por padrão — quem chega novo aprende sem saber que precisava procurar. Foi
	// assim que a tela de auditoria virou o HOM-016.
	it('nasce aberta', () => {
		render(AgendaLegend);
		expect(screen.getByRole('button', { name: /entenda a agenda/i })).toHaveAttribute(
			'aria-expanded',
			'true'
		);
	});

	it('fecha, e a escolha sobrevive à próxima visita', async () => {
		const { unmount } = render(AgendaLegend);
		await userEvent.click(screen.getByRole('button', { name: /entenda a agenda/i }));
		expect(screen.queryByText('Agendado')).not.toBeInTheDocument();
		unmount();

		render(AgendaLegend);
		expect(await screen.findByRole('button', { name: /entenda a agenda/i })).toHaveAttribute(
			'aria-expanded',
			'false'
		);
	});
});
