import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import Rail from './Rail.svelte';

describe('Rail', () => {
	it('lista os destinos do app (todos como links)', () => {
		const { getByTitle } = render(Rail, { props: { pathname: '/configuracoes/equipe' } });
		expect(getByTitle('Agenda')).toHaveAttribute('href', '/agenda');
		expect(getByTitle('Profissionais')).toHaveAttribute('href', '/profissionais');
		expect(getByTitle('Configurações')).toHaveAttribute('href', '/configuracoes');
	});

	it('destaca a seção ativa (aria-current)', () => {
		const { getByTitle } = render(Rail, { props: { pathname: '/configuracoes/equipe' } });
		expect(getByTitle('Configurações')).toHaveAttribute('aria-current', 'page');
		expect(getByTitle('Agenda')).not.toHaveAttribute('aria-current');
	});

	it('traz o toggle de tema no rodapé (o avatar do usuário mora no topbar)', () => {
		const { getByRole } = render(Rail, { props: { pathname: '/agenda', theme: 'light' } });
		expect(getByRole('button', { name: /tema/i })).toBeInTheDocument();
	});
});
