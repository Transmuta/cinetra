import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

import WeeklyHoursEditor from './WeeklyHoursEditor.svelte';
import type { WeekHours } from '$lib/scheduling';

// Segunda aberta, o resto fechado.
const hours: WeekHours = {
	'1': [['08:00', '12:00']],
	'2': [],
	'3': [],
	'4': [],
	'5': [],
	'6': [],
	'0': []
};

describe('WeeklyHoursEditor', () => {
	it('mostra os 7 dias com Segunda primeiro e Domingo por último', () => {
		const { getAllByText, getByText } = render(WeeklyHoursEditor, {
			props: { hours, onchange: () => {} }
		});
		expect(getByText('Segunda')).toBeInTheDocument();
		expect(getByText('Domingo')).toBeInTheDocument();
		// só Segunda está aberta → um único rótulo "Aberto" no toggle.
		expect(getAllByText('Aberto')).toHaveLength(1);
	});

	it('fechar um dia aberto emite periods vazio', async () => {
		const onchange = vi.fn();
		const { getByRole } = render(WeeklyHoursEditor, { props: { hours, onchange } });

		await fireEvent.click(getByRole('switch', { name: 'Segunda' }));
		expect(onchange).toHaveBeenCalledWith(expect.objectContaining({ '1': [] }));
	});

	it('abrir um dia fechado emite manhã e tarde', async () => {
		const onchange = vi.fn();
		const { getByRole } = render(WeeklyHoursEditor, { props: { hours, onchange } });

		await fireEvent.click(getByRole('switch', { name: 'Terça' }));
		expect(onchange).toHaveBeenCalledWith(
			expect.objectContaining({
				'2': [
					['08:00', '12:00'],
					['13:00', '18:00']
				]
			})
		);
	});

	it('Espelhar copia segunda para os dias úteis', async () => {
		const onchange = vi.fn();
		const { getByText } = render(WeeklyHoursEditor, { props: { hours, onchange } });

		await fireEvent.click(getByText('Espelhar Seg → Seg–Sex'));
		const arg = onchange.mock.calls[0][0] as WeekHours;
		expect(arg['5']).toEqual([['08:00', '12:00']]);
		expect(arg['6']).toEqual([]);
	});
});
