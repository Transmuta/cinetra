import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';
import ProfessionalChips from './ProfessionalChips.svelte';

const prof = (id: string, nome: string, nome_exibicao: string | null = null) => ({
	id,
	nome,
	nome_exibicao,
	crefito: null,
	cor_indice: 1,
	segue_horario_clinica: true
});

const base = {
	professionals: [prof('p1', 'Ana Paula Lima'), prof('p2', 'Bruno Sousa')],
	selected: 'p1',
	onSelect: () => {}
};

describe('ProfessionalChips', () => {
	// Divergência do protótipo (:1716), que usava `nome.split(' ')[1]`: "Ana Paula Lima"
	// virava "Paula", e quem tem nome só virava `undefined`.
	it('mostra o primeiro nome, não o segundo token', () => {
		render(ProfessionalChips, { props: base });
		expect(screen.getByRole('tab', { name: /Ana/ })).toBeInTheDocument();
		expect(screen.queryByRole('tab', { name: /Paula/ })).not.toBeInTheDocument();
	});

	it('nome de uma palavra só não quebra', () => {
		render(ProfessionalChips, {
			props: { ...base, professionals: [prof('p1', 'Madonna')] }
		});
		expect(screen.getByRole('tab', { name: /Madonna/ })).toBeInTheDocument();
	});

	it('prefere o nome de exibição', () => {
		render(ProfessionalChips, {
			props: {
				...base,
				professionals: [prof('p1', 'Ana Paula Lima', 'Dra. Aninha')]
			}
		});
		expect(screen.getByRole('tab', { name: /Dra\./ })).toBeInTheDocument();
	});

	it('marca o selecionado', () => {
		render(ProfessionalChips, { props: base });
		expect(screen.getByRole('tab', { name: /Ana/ })).toHaveAttribute('aria-selected', 'true');
		expect(screen.getByRole('tab', { name: /Bruno/ })).toHaveAttribute('aria-selected', 'false');
	});

	it('escolher um chip avisa quem manda', async () => {
		const onSelect = vi.fn();
		render(ProfessionalChips, { props: { ...base, onSelect } });
		await userEvent.click(screen.getByRole('tab', { name: /Bruno/ }));
		expect(onSelect).toHaveBeenCalledWith('p2');
	});
});
