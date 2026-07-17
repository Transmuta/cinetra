import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import Logo from './Logo.svelte';

describe('Logo', () => {
	it('renderiza o wordmark Cinetra (svg rotulado)', () => {
		const { getByRole } = render(Logo);
		expect(getByRole('img', { name: 'Cinetra' })).toBeInTheDocument();
	});

	it('a prop class controla a cor/altura (ex.: text-white sobre o painel escuro do auth)', () => {
		const { getByRole } = render(Logo, { props: { class: 'h-6.5 w-auto text-white' } });
		expect(getByRole('img', { name: 'Cinetra' })).toHaveClass('text-white');
	});
});
