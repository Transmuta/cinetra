import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';
import UserMenu from './UserMenu.svelte';
import type { Me } from '$lib/session';

const me: Me = {
	user: { id: 'u1', nome: 'Ana Paula', email: 'ana@x.com' },
	active_clinic_id: 'c1',
	papel: 'owner',
	professional_id: null,
	memberships: [
		{ clinic_id: 'c1', clinic_nome: 'Centro', papel: 'owner', professional_id: null },
		{ clinic_id: 'c2', clinic_nome: 'Zona Sul', papel: 'admin', professional_id: null }
	]
};

describe('UserMenu', () => {
	it('mostra o avatar com as iniciais e começa fechado', () => {
		const { getByTitle, queryByText } = render(UserMenu, { props: { me } });
		expect(getByTitle('Ana Paula')).toHaveTextContent('AP');
		expect(getByTitle('Ana Paula')).toHaveAttribute('aria-expanded', 'false');
		// fechado: os itens do menu não estão no DOM
		expect(queryByText('Meu perfil')).not.toBeInTheDocument();
	});

	it('ao abrir, lista perfil, clínicas, nova clínica e sair', async () => {
		const { getByTitle, getByText, getByRole } = render(UserMenu, { props: { me } });
		await fireEvent.click(getByTitle('Ana Paula'));

		// identidade
		expect(getByText('ana@x.com')).toBeInTheDocument();
		// perfil (stub por ora)
		expect(getByRole('link', { name: 'Meu perfil' })).toHaveAttribute('href', '/perfil');
		// clínicas
		expect(getByText('Centro')).toBeInTheDocument();
		expect(getByText('Zona Sul')).toBeInTheDocument();
		// nova clínica → onboarding no fluxo "nova"
		expect(getByRole('link', { name: 'Nova clínica' })).toHaveAttribute('href', '/comecar?nova=1');
	});

	it('a clínica ativa aparece marcada e desabilitada; a outra troca via POST', async () => {
		const { getByTitle, getByText, container } = render(UserMenu, { props: { me } });
		await fireEvent.click(getByTitle('Ana Paula'));

		const ativa = getByText('Centro').closest('button');
		expect(ativa).toBeDisabled();
		expect(ativa).toHaveAttribute('aria-current', 'true');

		const outra = getByText('Zona Sul').closest('button');
		expect(outra).not.toBeDisabled();

		// a troca é um POST com o clinic_id no corpo
		const forms = [...container.querySelectorAll('form[action="/auth/switch-clinic"]')];
		expect(forms).toHaveLength(2);
		const hidden = outra?.closest('form')?.querySelector('input[name="clinic_id"]');
		expect(hidden).toHaveValue('c2');
	});

	it('oferece Sair como POST (proteção CSRF)', async () => {
		const { getByTitle, getByText } = render(UserMenu, { props: { me } });
		await fireEvent.click(getByTitle('Ana Paula'));
		const form = getByText('Sair').closest('form');
		expect(form).toHaveAttribute('method', 'POST');
		expect(form).toHaveAttribute('action', '/auth/sign-out');
	});

	it('placement topbar (padrão) abre o popover para baixo/direita', async () => {
		const { getByTitle, container } = render(UserMenu, { props: { me } });
		await fireEvent.click(getByTitle('Ana Paula'));
		expect(container.querySelector('.right-0.top-full')).toBeInTheDocument();
	});

	it('placement rail abre o popover a partir do rail (esquerda/acima)', async () => {
		const { getByTitle, container } = render(UserMenu, { props: { me, placement: 'rail' } });
		await fireEvent.click(getByTitle('Ana Paula'));
		expect(container.querySelector('.left-full')).toBeInTheDocument();
	});
});
