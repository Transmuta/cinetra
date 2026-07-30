import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

// enhance como no-op action (não há runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import MemberModal from './MemberModal.svelte';
import type { Member } from '$lib/members';

const professionals = [{ id: 'p1', nome: 'Marina Lopes' }];
const noop = () => {};

describe('MemberModal — convite', () => {
	it('mostra nome/e-mail e posta em ?/invite', () => {
		const { getByRole, container } = render(MemberModal, {
			props: { mode: 'invite', professionals, onClose: noop }
		});
		expect(getByRole('dialog')).toBeInTheDocument();
		expect(getByRole('button', { name: 'Enviar convite' })).toBeInTheDocument();
		expect(container.querySelector('input[name="email"]')).toBeInTheDocument();
		expect(container.querySelector('form')).toHaveAttribute('action', '?/invite');
	});

	it('ao escolher Profissional, exige vínculo e desabilita o envio', async () => {
		const { getByRole, getByText } = render(MemberModal, {
			props: { mode: 'invite', professionals, onClose: noop }
		});
		await fireEvent.click(getByRole('button', { name: /Profissional/ }));
		expect(getByText(/exige um vínculo/i)).toBeInTheDocument();
		expect(getByRole('button', { name: 'Enviar convite' })).toBeDisabled();
	});
});

describe('MemberModal — edição', () => {
	const member: Member = {
		id: 'm1',
		nome: 'João',
		email: 'joao@x.com',
		papel: 'recepcao',
		status: 'ativo',
		professional_id: null
	};

	it('posta em ?/update com o id e sem campo de e-mail editável', () => {
		const { getByRole, container } = render(MemberModal, {
			props: { mode: 'edit', member, professionals, onClose: noop }
		});
		expect(getByRole('button', { name: 'Salvar' })).toBeInTheDocument();
		expect(container.querySelector('form')).toHaveAttribute('action', '?/update');
		expect(container.querySelector('input[name="id"]')).toHaveValue('m1');
		expect(container.querySelector('input[name="email"]')).toBeNull();
	});
});
