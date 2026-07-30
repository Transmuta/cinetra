import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

import ProfessionalHoursEditor from './ProfessionalHoursEditor.svelte';
import type { HoursRow, GradeState } from '$lib/professionals';

const clinicHours: HoursRow[] = [
	{ dow: 0, modo: null, periods: [] },
	{ dow: 1, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 2, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 3, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 4, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 5, modo: null, periods: [['08:00', '12:00'], ['13:00', '18:00']] },
	{ dow: 6, modo: null, periods: [['08:00', '12:00']] }
];

describe('ProfessionalHoursEditor', () => {
	it('domingo (clínica fechada) aparece travado', () => {
		const grade: GradeState = { 0: null, 1: [['09:00', '11:00']] };
		const { getByText, getByRole } = render(ProfessionalHoursEditor, {
			props: { clinicHours, grade, onchange: () => {} }
		});
		expect(getByText('Clínica fechada')).toBeInTheDocument();
		expect(getByRole('switch', { name: 'Domingo' })).toBeDisabled();
	});

	it('desligar um dia emite null', async () => {
		const onchange = vi.fn();
		const grade: GradeState = { 1: [['09:00', '11:00']] };
		const { getByRole } = render(ProfessionalHoursEditor, { props: { clinicHours, grade, onchange } });

		await fireEvent.click(getByRole('switch', { name: 'Segunda' }));
		expect(onchange).toHaveBeenCalledWith(expect.objectContaining({ 1: null }));
	});

	it('ligar um dia copia o expediente da clínica', async () => {
		const onchange = vi.fn();
		const grade: GradeState = { 1: null };
		const { getByRole } = render(ProfessionalHoursEditor, { props: { clinicHours, grade, onchange } });

		await fireEvent.click(getByRole('switch', { name: 'Segunda' }));
		expect(onchange).toHaveBeenCalledWith(
			expect.objectContaining({ 1: [['08:00', '12:00'], ['13:00', '18:00']] })
		);
	});

	it('período fora do horário da clínica mostra o aviso do invariante', () => {
		const grade: GradeState = { 1: [['07:00', '09:00']] };
		const { getByText } = render(ProfessionalHoursEditor, {
			props: { clinicHours, grade, onchange: () => {} }
		});
		expect(getByText(/dentro do horário da clínica/i)).toBeInTheDocument();
	});
});
