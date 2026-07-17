import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import Mark from './Mark.svelte';

describe('Mark', () => {
	it('renderiza o símbolo Cinetra (svg rotulado)', () => {
		const { getByRole } = render(Mark);
		expect(getByRole('img', { name: 'Cinetra' })).toBeInTheDocument();
	});

	it('usa a classe de tamanho padrão e aceita override', () => {
		const { getByRole } = render(Mark, { props: { class: 'size-9' } });
		expect(getByRole('img', { name: 'Cinetra' })).toHaveClass('size-9');
	});
});
