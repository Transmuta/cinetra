import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import PackageGradeModal from './PackageGradeModal.svelte';
import type { Package } from '$lib/packages';

const pkg: Package = {
	id: 'k1',
	nome: 'Pilates 10',
	status: 'ativo',
	total: 10,
	usadas: 3,
	restantes: 7,
	acabando: false,
	falta_punitiva: true,
	cor: '#0FB5A6',
	data_inicio: '2026-07-20',
	appointment_type_id: 't1',
	grade: { dows: [1, 3], horarios: { '1': '08:00', '3': '09:00' }, professional_id: 'pr1' }
};

const professionals = [
	{ id: 'pr1', nome: 'Ana Prado' },
	{ id: 'pr2', nome: 'Bruno Reis' }
];

function abrir(over: Record<string, unknown> = {}) {
	const onClose = vi.fn();
	render(PackageGradeModal, { pkg, professionals, onClose, ...over });
	return { onClose };
}

afterEach(cleanup);

describe('PackageGradeModal', () => {
	it('parte da grade atual do pacote', () => {
		abrir();
		expect(screen.getByRole('button', { name: 'Seg', pressed: true })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Qua', pressed: true })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Ter', pressed: false })).toBeInTheDocument();
		expect(screen.getByLabelText(/Horário de Seg/)).toHaveValue('08:00');
	});

	// A frase é o contrato da tela: sem ela, "ajustar a grade" parece que reescreve o pacote todo.
	it('diz que vale para as PRÓXIMAS e que remarca a agenda', () => {
		abrir();
		expect(screen.getByText(/próximas/i)).toBeInTheDocument();
		expect(screen.getByText(/remarca/i)).toBeInTheDocument();
	});

	it('o form manda a grade em formato plano, que o BFF remonta', () => {
		const { container } = render(PackageGradeModal, { pkg, professionals, onClose: vi.fn() });
		expect(container.querySelector('input[name="dows"]')).toHaveValue('1,3');
		expect(container.querySelector('input[name="horarios"]')).toHaveValue('1=08:00,3=09:00');
		expect(container.querySelector('input[name="package_id"]')).toHaveValue('k1');
	});

	it('marcar um dia novo o traz com horário padrão', async () => {
		const { container } = render(PackageGradeModal, { pkg, professionals, onClose: vi.fn() });
		await userEvent.click(screen.getByRole('button', { name: 'Sex' }));
		expect(container.querySelector('input[name="horarios"]')).toHaveValue(
			'1=08:00,3=09:00,5=08:00'
		);
	});

	it('sem nenhum dia marcado não dá para salvar', async () => {
		abrir();
		await userEvent.click(screen.getByRole('button', { name: 'Seg' }));
		await userEvent.click(screen.getByRole('button', { name: 'Qua' }));

		expect(screen.getByText(/selecione ao menos um dia/i)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /Salvar grade/ })).toBeDisabled();
	});

	it('erro do servidor aparece no modal, que fica aberto', () => {
		abrir({ erro: 'Choca com outro agendamento.' });
		expect(screen.getByText('Choca com outro agendamento.')).toBeInTheDocument();
	});

	it('Cancelar chama onClose', async () => {
		const { onClose } = abrir();
		await userEvent.click(screen.getByRole('button', { name: 'Cancelar' }));
		expect(onClose).toHaveBeenCalledOnce();
	});
});
