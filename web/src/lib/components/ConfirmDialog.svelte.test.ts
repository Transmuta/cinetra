import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';

import ConfirmDialog from './ConfirmDialog.svelte';

const message = createRawSnippet(() => ({
	render: () => '<span>Remover o acesso de Fulano?</span>'
}));
const noop = () => {};

const base = {
	title: 'Remover acesso',
	confirmLabel: 'Remover acesso',
	children: message
};

describe('ConfirmDialog', () => {
	it('renderiza título, mensagem e os dois botões (Voltar por padrão)', () => {
		const { getByRole, getByText } = render(ConfirmDialog, {
			props: { ...base, onConfirm: noop, onClose: noop }
		});
		expect(getByRole('dialog', { name: 'Remover acesso' })).toBeInTheDocument();
		expect(getByText('Remover o acesso de Fulano?')).toBeInTheDocument();
		expect(getByRole('button', { name: 'Voltar' })).toBeInTheDocument();
		expect(getByRole('button', { name: 'Remover acesso' })).toBeInTheDocument();
	});

	it('confirma na ação destrutiva e fecha no Voltar', async () => {
		const onConfirm = vi.fn();
		const onClose = vi.fn();
		const { getByRole } = render(ConfirmDialog, { props: { ...base, onConfirm, onClose } });

		await fireEvent.click(getByRole('button', { name: 'Remover acesso' }));
		expect(onConfirm).toHaveBeenCalledOnce();
		expect(onClose).not.toHaveBeenCalled();

		await fireEvent.click(getByRole('button', { name: 'Voltar' }));
		expect(onClose).toHaveBeenCalledOnce();
	});

	// Desabilitar sozinho não é feedback: um botão apagado parece quebrado, e a pessoa insiste no
	// clique. O giro (e o `aria-busy`, para quem usa leitor de tela) diz que a ação está indo.
	it('enquanto submitting, desabilita E mostra que está indo', () => {
		const { getByRole } = render(ConfirmDialog, {
			props: { ...base, submitting: true, onConfirm: noop, onClose: noop }
		});
		const botao = getByRole('button', { name: 'Remover acesso' });
		expect(botao).toBeDisabled();
		expect(botao).toHaveAttribute('aria-busy', 'true');
		expect(botao.querySelector('.animate-spin')).not.toBeNull();
	});
});
