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

	describe('aponta o input com problema (não só um toast genérico)', () => {
		it('período válido não marca erro', () => {
			const { getByLabelText, queryByRole } = render(PeriodEditor, {
				props: { periods: manha, onchange: () => {} }
			});
			expect(getByLabelText('Início do período 1')).toHaveAttribute('aria-invalid', 'false');
			expect(getByLabelText('Início do período 1').className).not.toContain('border-danger');
			expect(queryByRole('alert')).toBeNull();
		});

		it('início ≥ fim marca AQUELE período em vermelho e explica o motivo', () => {
			const { getByLabelText, getByRole } = render(PeriodEditor, {
				props: { periods: [['14:00', '12:00']] as Period[], onchange: () => {} }
			});
			const ini = getByLabelText('Início do período 1');
			expect(ini).toHaveAttribute('aria-invalid', 'true');
			expect(ini.className).toContain('border-danger');
			expect(getByLabelText('Fim do período 1').className).toContain('border-danger');
			expect(getByRole('alert')).toHaveTextContent('O horário final deve ser depois do inicial.');
		});

		it('marca só o período errado, deixando o correto normal', () => {
			const { getByLabelText } = render(PeriodEditor, {
				props: {
					periods: [
						['08:00', '12:00'],
						['16:00', '15:00']
					] as Period[],
					onchange: () => {}
				}
			});
			expect(getByLabelText('Início do período 1').className).not.toContain('border-danger');
			expect(getByLabelText('Início do período 2').className).toContain('border-danger');
		});

		it('sobreposição explica e marca o par', () => {
			const { getByLabelText, getByRole } = render(PeriodEditor, {
				props: {
					periods: [
						['08:00', '13:00'],
						['12:00', '18:00']
					] as Period[],
					onchange: () => {}
				}
			});
			expect(getByRole('alert')).toHaveTextContent('Os períodos não podem se sobrepor.');
			expect(getByLabelText('Início do período 1').className).toContain('border-danger');
			expect(getByLabelText('Início do período 2').className).toContain('border-danger');
		});
	});
});
