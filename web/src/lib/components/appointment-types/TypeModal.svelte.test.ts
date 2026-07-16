import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';
import { vi } from 'vitest';

// enhance como no-op action (não há runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import TypeModal from './TypeModal.svelte';
import type { AppointmentType } from '$lib/appointment-types';

const noop = () => {};
const props = { capacidadePadrao: 4, onClose: noop };

describe('TypeModal — novo tipo', () => {
	it('abre com o título do protótipo (:2404) e posta em ?/save', () => {
		const { getByRole, container } = render(TypeModal, { props });

		expect(getByRole('dialog', { name: 'Novo tipo de atendimento' })).toBeInTheDocument();
		expect(container.querySelector('form')).toHaveAttribute('action', '?/save');
		// sem id: o servidor decide criar vs. atualizar pela presença dele
		expect(container.querySelector('input[name="id"]')).toBeNull();
	});

	it('nasce com os defaults do "Novo tipo" (:3229)', () => {
		const { container } = render(TypeModal, { props });

		expect(container.querySelector('input[name="duracao_minutos"]')).toHaveValue(50);
		expect(container.querySelector('input[name="cor"]')).toHaveValue('#0072B2');
		expect(container.querySelector('input[name="icon"]')).toHaveValue('Activity');
		expect(container.querySelector('input[name="grupo"]')).toHaveValue('false');
	});

	it('Salvar nasce desabilitado e libera quando o nome é preenchido (:2404)', async () => {
		const { getByRole, getByLabelText } = render(TypeModal, { props });

		const salvar = getByRole('button', { name: 'Salvar' });
		expect(salvar).toBeDisabled();

		await fireEvent.input(getByLabelText('Nome'), { target: { value: 'Sessão' } });
		expect(salvar).toBeEnabled();
	});

	it('nome só de espaços não conta como nome', async () => {
		const { getByRole, getByLabelText } = render(TypeModal, { props });
		await fireEvent.input(getByLabelText('Nome'), { target: { value: '   ' } });
		expect(getByRole('button', { name: 'Salvar' })).toBeDisabled();
	});

	it('a duração respeita os limites do protótipo (:2396)', () => {
		const { container } = render(TypeModal, { props });
		const dur = container.querySelector('input[name="duracao_minutos"]');
		expect(dur).toHaveAttribute('min', '10');
		expect(dur).toHaveAttribute('step', '5');
	});

	it('oferece só a paleta fechada: 8 cores e 10 ícones', () => {
		const { getByRole } = render(TypeModal, { props });
		expect(getByRole('group', { name: 'Cor' }).querySelectorAll('button')).toHaveLength(8);
		expect(getByRole('group', { name: 'Ícone' }).querySelectorAll('button')).toHaveLength(10);
	});

	it('escolher cor e ícone troca o que vai no corpo', async () => {
		const { getByRole, container } = render(TypeModal, { props });

		await fireEvent.click(getByRole('button', { name: 'Cor #CC79A7' }));
		expect(container.querySelector('input[name="cor"]')).toHaveValue('#CC79A7');

		await fireEvent.click(getByRole('button', { name: 'Ícone Users' }));
		expect(container.querySelector('input[name="icon"]')).toHaveValue('Users');
	});

	it('a cor escolhida fica marcada para quem não enxerga a borda', async () => {
		const { getByRole } = render(TypeModal, { props });
		const roxo = getByRole('button', { name: 'Cor #7A52CC' });

		expect(roxo).toHaveAttribute('aria-pressed', 'false');
		await fireEvent.click(roxo);
		expect(roxo).toHaveAttribute('aria-pressed', 'true');
	});

	it('capacidade só existe quando é atendimento em grupo (:2402)', async () => {
		const { getByLabelText, queryByLabelText, container } = render(TypeModal, { props });

		expect(queryByLabelText('Capacidade do grupo')).toBeNull();

		await fireEvent.click(getByLabelText('Atendimento em grupo'));

		expect(container.querySelector('input[name="grupo"]')).toHaveValue('true');
		// default do modal = o padrão da clínica, não um 4 hardcoded (doc 20 §1)
		expect(getByLabelText('Capacidade do grupo')).toHaveValue(4);
		expect(getByLabelText('Capacidade do grupo')).toHaveAttribute('min', '2');
	});

	it('a capacidade padrão vem da clínica', async () => {
		const { getByLabelText } = render(TypeModal, {
			props: { ...props, capacidadePadrao: 6 }
		});
		await fireEvent.click(getByLabelText('Atendimento em grupo'));
		expect(getByLabelText('Capacidade do grupo')).toHaveValue(6);
	});

	it('erro da API aparece dentro do modal, não some num toast', () => {
		const { getByText } = render(TypeModal, {
			props: { ...props, error: 'Já existe um tipo com esse nome.' }
		});
		expect(getByText('Já existe um tipo com esse nome.')).toBeInTheDocument();
	});
});

describe('TypeModal — edição', () => {
	const type: AppointmentType = {
		id: 't4',
		nome: 'Pilates',
		sigla: 'PIL',
		duracao_minutos: 50,
		cor: '#CC79A7',
		icon: 'Users',
		grupo: true,
		capacidade: 8,
		ativo: true
	};

	it('abre com o título de edição e o id no corpo (:2404)', () => {
		const { getByRole, container } = render(TypeModal, { props: { ...props, type } });

		expect(getByRole('dialog', { name: 'Editar tipo' })).toBeInTheDocument();
		expect(container.querySelector('input[name="id"]')).toHaveValue('t4');
	});

	it('carrega os valores do tipo, inclusive a capacidade da turma', () => {
		const { getByLabelText, container } = render(TypeModal, { props: { ...props, type } });

		expect(getByLabelText('Nome')).toHaveValue('Pilates');
		expect(getByLabelText('Duração (min)')).toHaveValue(50);
		expect(getByLabelText('Capacidade do grupo')).toHaveValue(8);
		expect(container.querySelector('input[name="cor"]')).toHaveValue('#CC79A7');
		expect(container.querySelector('input[name="icon"]')).toHaveValue('Users');
		expect(container.querySelector('input[name="grupo"]')).toHaveValue('true');
	});

	it('Salvar já vem liberado — o nome veio preenchido', () => {
		const { getByRole } = render(TypeModal, { props: { ...props, type } });
		expect(getByRole('button', { name: 'Salvar' })).toBeEnabled();
	});
});
