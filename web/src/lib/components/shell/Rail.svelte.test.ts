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

	it('oferece Sair como POST (proteção CSRF)', () => {
		const { getByTitle, container } = render(Rail, { props: { pathname: '/agenda' } });
		expect(getByTitle('Sair')).toBeInTheDocument();
		const form = container.querySelector('form');
		expect(form).toHaveAttribute('method', 'POST');
		expect(form).toHaveAttribute('action', '/auth/sign-out');
	});
});
