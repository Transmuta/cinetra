import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import Topbar from './Topbar.svelte';
import type { Me } from '$lib/session';

const me: Me = {
	user: { id: 'u1', nome: 'Ana Paula', email: 'ana@x.com' },
	active_clinic_id: 'c1',
	papel: 'admin',
	professional_id: null,
	memberships: []
};

describe('Topbar', () => {
	it('mostra o título da seção, a clínica e as iniciais do usuário', () => {
		const { getByRole, getByText } = render(Topbar, {
			props: { pathname: '/configuracoes/equipe', me, clinicName: 'Centro', theme: 'light' }
		});
		expect(getByRole('heading', { name: 'Configurações' })).toBeInTheDocument();
		expect(getByText('Centro')).toBeInTheDocument();
		expect(getByText('AP')).toBeInTheDocument();
		expect(getByText('ana@x.com')).toBeInTheDocument();
	});
});
