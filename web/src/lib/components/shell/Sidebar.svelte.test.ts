import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import Sidebar from './Sidebar.svelte';

describe('Sidebar', () => {
	it('em Configurações mostra a sub-nav de ajustes e o nome da clínica', () => {
		const { getByRole, getByText } = render(Sidebar, {
			props: { pathname: '/configuracoes/equipe', clinicName: 'Clínica Centro' }
		});
		expect(getByText('Clínica Centro')).toBeInTheDocument();
		expect(getByRole('link', { name: 'Equipe & acessos' })).toHaveAttribute(
			'href',
			'/configuracoes/equipe'
		);
		expect(getByRole('link', { name: 'Tipos de atendimento' })).toHaveAttribute(
			'href',
			'/configuracoes/tipos'
		);
	});

	it('destaca a aba atual', () => {
		const { getByRole } = render(Sidebar, { props: { pathname: '/configuracoes/equipe' } });
		expect(getByRole('link', { name: 'Equipe & acessos' })).toHaveAttribute('aria-current', 'page');
		expect(getByRole('link', { name: 'Horário' })).not.toHaveAttribute('aria-current');
	});

	it('fora de Configurações não renderiza a sub-nav', () => {
		const { queryByRole } = render(Sidebar, { props: { pathname: '/agenda' } });
		expect(queryByRole('link', { name: 'Equipe & acessos' })).toBeNull();
	});
});
