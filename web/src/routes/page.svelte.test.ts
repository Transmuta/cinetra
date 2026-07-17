import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';
import Page from './+page.svelte';

describe('landing /', () => {
	it('a headline principal aparece', () => {
		const { getByRole } = render(Page);
		expect(getByRole('heading', { name: /cuida de si mesma/i })).toBeInTheDocument();
	});

	it('os CTAs apontam para criar conta e entrar', () => {
		const { getAllByRole } = render(Page);
		const hrefs = getAllByRole('link').map((a) => a.getAttribute('href'));
		expect(hrefs).toContain('/criar-conta');
		expect(hrefs).toContain('/entrar');
	});

	it('o toggle de cobrança troca o preço exibido (anual → mensal)', async () => {
		const { getByText } = render(Page);
		// Anual por padrão: plano Clínica R$ 289.
		expect(getByText(/289/)).toBeInTheDocument();

		await fireEvent.click(getByText('Mensal'));
		// Mensal: plano Clínica R$ 349.
		expect(getByText(/349/)).toBeInTheDocument();
	});
});
