import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';

import Drawer from './Drawer.svelte';

const body = createRawSnippet(() => ({ render: () => '<p>corpo do drawer</p>' }));
const header = createRawSnippet(() => ({ render: () => '<span>Agendado</span>' }));
const footer = createRawSnippet(() => ({ render: () => '<button>ação</button>' }));
const noop = () => {};

afterEach(() => document.querySelectorAll('[data-modal]').forEach((el) => el.remove()));

describe('Drawer (shell)', () => {
	it('renderiza dialog com rótulo acessível, cabeçalho, corpo e rodapé', () => {
		const { getByRole, getByText } = render(Drawer, {
			props: { label: 'Detalhes', onClose: noop, children: body, header, footer }
		});
		expect(getByRole('dialog', { name: 'Detalhes' })).toBeInTheDocument();
		expect(getByText('Agendado')).toBeInTheDocument();
		expect(getByText('corpo do drawer')).toBeInTheDocument();
		expect(getByRole('button', { name: 'ação' })).toBeInTheDocument();
	});

	it('sem footer não há rodapé', () => {
		const { queryByRole } = render(Drawer, {
			props: { label: 'D', onClose: noop, children: body }
		});
		expect(queryByRole('button', { name: 'ação' })).toBeNull();
	});

	it('fecha no X, no clique no overlay e no Esc — mas não no clique dentro do painel', async () => {
		const onClose = vi.fn();
		const { getByRole, getByLabelText, container } = render(Drawer, {
			props: { label: 'D', onClose, children: body }
		});

		await fireEvent.click(getByLabelText('Fechar'));
		expect(onClose).toHaveBeenCalledTimes(1);

		const overlay = container.querySelector('[role="presentation"]')!;
		await fireEvent.click(overlay);
		expect(onClose).toHaveBeenCalledTimes(2);

		await fireEvent.keyDown(window, { key: 'Escape' });
		expect(onClose).toHaveBeenCalledTimes(3);

		await fireEvent.click(getByRole('dialog'));
		expect(onClose).toHaveBeenCalledTimes(3);
	});

	it('outra tecla não fecha', async () => {
		const onClose = vi.fn();
		render(Drawer, { props: { label: 'D', onClose, children: body } });

		await fireEvent.keyDown(window, { key: 'Enter' });
		expect(onClose).not.toHaveBeenCalled();
	});

	// Com um modal por cima (remarcar, confirmar cancelamento) os dois escutam a janela: o Esc
	// é do modal, senão uma tecla fecharia os dois de uma vez.
	it('com um modal aberto por cima, o Esc não fecha o drawer', async () => {
		const onClose = vi.fn();
		render(Drawer, { props: { label: 'D', onClose, children: body } });

		const modal = document.createElement('div');
		modal.setAttribute('data-modal', '');
		document.body.appendChild(modal);

		await fireEvent.keyDown(window, { key: 'Escape' });
		expect(onClose).not.toHaveBeenCalled();

		modal.remove();
		await fireEvent.keyDown(window, { key: 'Escape' });
		expect(onClose).toHaveBeenCalledTimes(1);
	});
});
