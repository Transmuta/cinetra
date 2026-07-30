import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import ExceptionForm from './ExceptionForm.svelte';

describe('ExceptionForm', () => {
	it('posta em ?/add e nasce em "Fechar o dia inteiro"', () => {
		const { container } = render(ExceptionForm, { props: {} });
		expect(container.querySelector('form')).toHaveAttribute('action', '?/add');
		expect(container.querySelector('input[name="tipo"]')).toHaveValue('fechado');
	});

	it('"Adicionar" fica desabilitado até haver data', async () => {
		const { getByRole, getByLabelText } = render(ExceptionForm, { props: {} });

		const add = getByRole('button', { name: 'Adicionar exceção' });
		expect(add).toBeDisabled();

		await fireEvent.input(getByLabelText('Data da exceção'), { target: { value: '2026-07-09' } });
		expect(add).toBeEnabled();
	});

	it('fechado não mostra o editor de períodos; horário mostra', async () => {
		const { getByRole, queryByLabelText, container } = render(ExceptionForm, { props: {} });

		// fechado: sem períodos no corpo.
		expect(queryByLabelText('Início do período 1')).toBeNull();
		expect(container.querySelector('input[name="periods"]')).toBeNull();

		await fireEvent.click(getByRole('button', { name: 'Horário específico' }));

		expect(container.querySelector('input[name="tipo"]')).toHaveValue('horario');
		expect(queryByLabelText('Início do período 1')).not.toBeNull();
		expect(container.querySelector('input[name="periods"]')).not.toBeNull();
	});

	it('erro da API aparece no formulário', () => {
		const { getByText } = render(ExceptionForm, { props: { error: 'Já existe uma exceção nessa data.' } });
		expect(getByText('Já existe uma exceção nessa data.')).toBeInTheDocument();
	});

	it('"Adicionar" trava quando o período do "Horário específico" é inválido', async () => {
		const { getByRole, getByLabelText } = render(ExceptionForm, { props: {} });

		// data preenchida + horário específico: período default (08:00–12:00) é válido → habilitado.
		await fireEvent.input(getByLabelText('Data da exceção'), { target: { value: '2026-12-25' } });
		await fireEvent.click(getByRole('button', { name: 'Horário específico' }));
		const add = getByRole('button', { name: 'Adicionar exceção' });
		expect(add).toBeEnabled();

		// fim antes do início torna o período inválido → o Adicionar trava (não deixa mandar 422).
		await fireEvent.change(getByLabelText('Fim do período 1'), { target: { value: '07:00' } });
		expect(add).toBeDisabled();
	});
});
