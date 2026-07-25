import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import PackageBulkModal from './PackageBulkModal.svelte';
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
	grade: { dows: [1], horarios: { '1': '08:00' }, professional_id: 'pr2' }
};

const professionals = [
	{ id: 'pr1', nome: 'Dra. Ana' },
	{ id: 'pr2', nome: 'Dr. Bruno' }
];

afterEach(cleanup);

describe('PackageBulkModal', () => {
	it('sem escolher o que aplicar, o botão fica desabilitado', () => {
		render(PackageBulkModal, { pkg, professionals, onClose: () => {} });
		expect(screen.getByRole('button', { name: /Aplicar/ })).toBeDisabled();
	});

	it('marcar "mudar profissional" revela o seletor já na grade do pacote', async () => {
		render(PackageBulkModal, { pkg, professionals, onClose: () => {} });

		await userEvent.click(screen.getByLabelText(/Mudar o profissional/));

		const select = screen.getByRole('combobox') as HTMLSelectElement;
		expect(select.value).toBe('pr2');
		expect(screen.getByRole('button', { name: /Aplicar/ })).toBeEnabled();
	});

	it('marcar "mudar horário" só habilita depois de ter horário', async () => {
		const { container } = render(PackageBulkModal, { pkg, professionals, onClose: () => {} });

		await userEvent.click(screen.getByLabelText(/Mudar o horário/));
		expect(screen.getByRole('button', { name: /Aplicar/ })).toBeDisabled();

		const hora = container.querySelector('input[name="hhmm"]') as HTMLInputElement;
		await userEvent.type(hora, '09:30');
		expect(screen.getByRole('button', { name: /Aplicar/ })).toBeEnabled();
	});

	// O texto é parte da correção: no protótipo a massa mexia no bloco e arrastava a turma junto.
	it('avisa que numa turma só a presença deste paciente se move', () => {
		render(PackageBulkModal, { pkg, professionals, onClose: () => {} });
		expect(screen.getByText(/só a presença deste paciente se move/i)).toBeInTheDocument();
	});

	it('o "aplicar mesmo assim" só existe depois de um erro', async () => {
		const { unmount } = render(PackageBulkModal, { pkg, professionals, onClose: () => {} });
		expect(screen.queryByLabelText(/Aplicar mesmo assim/)).not.toBeInTheDocument();
		unmount();

		render(PackageBulkModal, {
			pkg,
			professionals,
			erro: 'Este horário conflita com outro agendamento.',
			onClose: () => {}
		});
		expect(screen.getByText(/conflita com outro agendamento/)).toBeInTheDocument();

		const forcar = screen.getByLabelText(/Aplicar mesmo assim/);
		await userEvent.click(forcar);
		expect((document.querySelector('input[name="forcar"]') as HTMLInputElement).value).toBe('true');
	});
});
