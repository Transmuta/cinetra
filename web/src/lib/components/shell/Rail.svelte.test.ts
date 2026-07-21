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

	it('o sino é um link para /notificacoes', () => {
		const { getByTitle } = render(Rail, { props: { pathname: '/agenda' } });
		expect(getByTitle('Notificações')).toHaveAttribute('href', '/notificacoes');
	});

	it('sem não-lidas não mostra badge; com não-lidas mostra o número', () => {
		const semBadge = render(Rail, { props: { pathname: '/agenda', unread: 0 } });
		expect(semBadge.getByLabelText('Notificações')).toBeInTheDocument();

		const comBadge = render(Rail, { props: { pathname: '/agenda', unread: 3 } });
		expect(comBadge.getByText('3')).toBeInTheDocument();
		expect(comBadge.getByLabelText('Notificações (3 não lidas)')).toBeInTheDocument();
	});

	it('acima de 9 o badge vira "9+"', () => {
		const { getByText } = render(Rail, { props: { pathname: '/agenda', unread: 42 } });
		expect(getByText('9+')).toBeInTheDocument();
	});

	it('destaca o sino quando em /notificacoes', () => {
		const { getByTitle } = render(Rail, { props: { pathname: '/notificacoes' } });
		expect(getByTitle('Notificações')).toHaveAttribute('aria-current', 'page');
	});
});
