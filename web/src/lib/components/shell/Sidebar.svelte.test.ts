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
		expect(getByRole('link', { name: 'Clínica' })).toHaveAttribute('href', '/configuracoes/clinica');
		expect(getByRole('link', { name: 'Equipe & acessos' })).toHaveAttribute(
			'href',
			'/configuracoes/equipe'
		);
		expect(getByRole('link', { name: 'Tipos de atendimento' })).toHaveAttribute(
			'href',
			'/configuracoes/tipos'
		);
	});

	it('no topo mostra o nome da clínica (sem a marca Cinetra) com CNPJ mascarado e endereço', () => {
		const { getByText, queryByText } = render(Sidebar, {
			props: {
				pathname: '/agenda',
				clinicName: 'Clínica Vida',
				clinicCnpj: '12ABC34501DE35',
				clinicEndereco: 'Rua X, 100'
			}
		});
		expect(getByText('Clínica Vida')).toBeInTheDocument();
		expect(getByText('12.ABC.345/01DE-35')).toBeInTheDocument();
		expect(getByText('Rua X, 100')).toBeInTheDocument();
		// o nome substitui a logomarca: "Cinetra" não aparece no sidebar (vive no rail).
		expect(queryByText('Cinetra')).toBeNull();
	});

	it('sem nome de clínica, cai na marca Cinetra', () => {
		const { getByText } = render(Sidebar, { props: { pathname: '/agenda' } });
		expect(getByText('Cinetra')).toBeInTheDocument();
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
