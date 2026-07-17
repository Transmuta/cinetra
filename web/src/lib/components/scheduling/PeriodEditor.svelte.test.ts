import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

import PeriodEditor from './PeriodEditor.svelte';
import type { Period } from '$lib/scheduling';

const manha: Period[] = [['08:00', '12:00']];

describe('PeriodEditor', () => {
	it('renderiza uma linha por período', () => {
		const { getByLabelText } = render(PeriodEditor, {
			props: {
				periods: [
					['08:00', '12:00'],
					['13:00', '18:00']
				] as Period[],
				onchange: () => {}
			}
		});
		expect(getByLabelText('Início do período 1')).toHaveValue('08:00');
		expect(getByLabelText('Fim do período 2')).toHaveValue('18:00');
	});

	it('"+ período" emite a lista com o novo período', async () => {
		const onchange = vi.fn();
		const { getByText } = render(PeriodEditor, { props: { periods: manha, onchange } });

		await fireEvent.click(getByText('período'));
		expect(onchange).toHaveBeenCalledWith([
			['08:00', '12:00'],
			['12:00', '18:00']
		]);
	});

	it('editar o início emite a lista alterada', async () => {
		const onchange = vi.fn();
		const { getByLabelText } = render(PeriodEditor, { props: { periods: manha, onchange } });

		await fireEvent.change(getByLabelText('Início do período 1'), { target: { value: '09:00' } });
		expect(onchange).toHaveBeenCalledWith([['09:00', '12:00']]);
	});

	it('remover emite a lista sem aquele período', async () => {
		const onchange = vi.fn();
		const { getByLabelText } = render(PeriodEditor, { props: { periods: manha, onchange } });

		await fireEvent.click(getByLabelText('Remover período 1'));
		expect(onchange).toHaveBeenCalledWith([]);
	});
});
