import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import Topbar from './Topbar.svelte';
import type { Me } from '$lib/session';
import { meFixture } from '$lib/testing/fixtures';

const me: Me = meFixture({
	user: { id: 'u1', nome: 'Ana Paula', email: 'ana@x.com' },
	papel: 'admin',
	memberships: []
});

describe('Topbar', () => {
	it('mostra o título da seção e o avatar do usuário (menu)', () => {
		const { getByRole, getByTitle } = render(Topbar, {
			props: { pathname: '/configuracoes/equipe', me }
		});
		expect(getByRole('heading', { name: 'Configurações' })).toBeInTheDocument();
		expect(getByTitle('Ana Paula')).toHaveTextContent('AP');
	});

	it('tem o hambúrguer para abrir o menu no mobile', () => {
		const { getByRole } = render(Topbar, { props: { pathname: '/agenda', me } });
		expect(getByRole('button', { name: 'Abrir menu' })).toBeInTheDocument();
	});

	it('não traz mais o toggle de tema (foi para o rail)', () => {
		const { queryByRole } = render(Topbar, { props: { pathname: '/agenda', me } });
		expect(queryByRole('button', { name: /tema/i })).toBeNull();
	});
});
