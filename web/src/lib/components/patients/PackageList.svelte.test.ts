import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import PackageList from './PackageList.svelte';
import type { Package } from '$lib/packages';

const pkg = (over: Partial<Package> = {}): Package => ({
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
	grade: { dows: [1, 3], horarios: { '1': '08:00', '3': '09:00' }, professional_id: 'pr1' },
	...over
});

afterEach(cleanup);

describe('PackageList', () => {
	it('lista vazia mostra o placeholder', () => {
		render(PackageList, { packages: [] });
		expect(screen.getByText(/nenhum pacote ainda/i)).toBeInTheDocument();
	});

	it('mostra nome, contador de restantes e o chip de status', () => {
		render(PackageList, { packages: [pkg()] });
		expect(screen.getByText('Pilates 10')).toBeInTheDocument();
		expect(screen.getByText(/7 de 10 restantes/)).toBeInTheDocument();
		expect(screen.getByText('Ativo')).toBeInTheDocument();
	});

	it('sem canManage não há ações nem "novo pacote"', () => {
		render(PackageList, { packages: [pkg()] });
		expect(screen.queryByText('Novo pacote')).not.toBeInTheDocument();
		expect(screen.queryByText('Pausar')).not.toBeInTheDocument();
	});

	it('ativo com canManage oferece Pausar e Cancelar', () => {
		render(PackageList, { packages: [pkg({ status: 'ativo' })], canManage: true });
		expect(screen.getByText('Pausar')).toBeInTheDocument();
		expect(screen.getByText('Cancelar')).toBeInTheDocument();
		expect(screen.queryByText('Retomar')).not.toBeInTheDocument();
	});

	it('pausado com canManage oferece Retomar (não Pausar)', () => {
		render(PackageList, { packages: [pkg({ status: 'pausado' })], canManage: true });
		expect(screen.getByText('Retomar')).toBeInTheDocument();
		expect(screen.queryByText('Pausar')).not.toBeInTheDocument();
	});

	it('cancelado não oferece ações de ciclo de vida', () => {
		render(PackageList, { packages: [pkg({ status: 'cancelado' })], canManage: true });
		expect(screen.queryByText('Pausar')).not.toBeInTheDocument();
		expect(screen.queryByText('Retomar')).not.toBeInTheDocument();
	});

	it('"Novo pacote" chama onNew', async () => {
		const onNew = vi.fn();
		render(PackageList, { packages: [], canManage: true, onNew });
		await userEvent.click(screen.getByText('Novo pacote'));
		expect(onNew).toHaveBeenCalledOnce();
	});

	it('Cancelar abre a confirmação destrutiva', async () => {
		render(PackageList, { packages: [pkg()], canManage: true });
		await userEvent.click(screen.getByText('Cancelar'));
		// o ConfirmDialog aparece com a consequência
		expect(screen.getByText(/serão canceladas e/i)).toBeInTheDocument();
	});
});

describe('PackageList — massa (doc 41 etapa 3)', () => {
	it('pacote ativo oferece "Ajustar sessões" e devolve o pacote ao pai', async () => {
		const onBulk = vi.fn();
		render(PackageList, { packages: [pkg()], canManage: true, onBulk });

		await userEvent.click(screen.getByRole('button', { name: /Ajustar sessões/ }));

		expect(onBulk).toHaveBeenCalledWith(expect.objectContaining({ id: 'k1' }));
	});

	it('pacote PAUSADO não oferece a massa — as sessões estão seguradas, fora da agenda', () => {
		render(PackageList, {
			packages: [pkg({ status: 'pausado' })],
			canManage: true,
			onBulk: vi.fn()
		});
		expect(screen.queryByRole('button', { name: /Ajustar sessões/ })).not.toBeInTheDocument();
	});

	it('sem onBulk (pai que não trata massa) o botão não aparece', () => {
		render(PackageList, { packages: [pkg()], canManage: true });
		expect(screen.queryByRole('button', { name: /Ajustar sessões/ })).not.toBeInTheDocument();
	});
});
