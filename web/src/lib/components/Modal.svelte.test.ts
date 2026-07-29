import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';

import Modal from './Modal.svelte';

const body = createRawSnippet(() => ({ render: () => '<p>corpo do modal</p>' }));
const footer = createRawSnippet(() => ({ render: () => '<button>ação</button>' }));
const noop = () => {};

describe('Modal (shell)', () => {
	it('renderiza dialog com título acessível, corpo e rodapé', () => {
		const { getByRole, getByText } = render(Modal, {
			props: { title: 'Título X', onClose: noop, children: body, footer }
		});
		expect(getByRole('dialog', { name: 'Título X' })).toBeInTheDocument();
		expect(getByRole('heading', { name: 'Título X' })).toBeInTheDocument();
		expect(getByText('corpo do modal')).toBeInTheDocument();
		expect(getByRole('button', { name: 'ação' })).toBeInTheDocument();
	});

	it('sem footer não há rodapé', () => {
		const { queryByRole } = render(Modal, {
			props: { title: 'T', onClose: noop, children: body }
		});
		expect(queryByRole('button', { name: 'ação' })).toBeNull();
	});

	it('fecha no X, no clique fora e no Esc — mas não no clique dentro', async () => {
		const onClose = vi.fn();
		const { getByRole, getByLabelText, container } = render(Modal, {
			props: { title: 'T', onClose, children: body }
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

	// AN-08 (WCAG 2.4.3): abrir move o foco para o diálogo; fechar devolve a quem abriu. Sem
	// isto o Tab passeava pela tela de trás do overlay.
	it('abrir foca o diálogo e fechar devolve o foco ao gatilho', async () => {
		const gatilho = document.createElement('button');
		document.body.appendChild(gatilho);
		gatilho.focus();

		const { getByRole, unmount } = render(Modal, {
			props: { title: 'T', onClose: () => {}, children: body }
		});
		await Promise.resolve();

		expect(document.activeElement).toBe(getByRole('dialog'));

		unmount();
		expect(document.activeElement).toBe(gatilho);
		gatilho.remove();
	});
});
