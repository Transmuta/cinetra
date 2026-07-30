import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

// enhance como no-op (sem runtime de app nos testes de componente).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));

import Page from './+page.svelte';
import type { Me } from '$lib/session';
import { meFixture, membershipFixture } from '$lib/testing/fixtures';

const me: Me = meFixture({
	user: { id: 'u1', nome: 'Bianca Souza', email: 'bianca@ex.com' },
	active_clinic_id: 'c1',
	memberships: [
		membershipFixture({ clinic_id: 'c1', clinic_nome: 'Clínica Vida', papel: 'owner' }),
		membershipFixture({ clinic_id: 'c2', clinic_nome: 'Clínica Sul', papel: 'profissional' })
	]
});

function data(over: Partial<Me> = {}) {
	return { theme: null, unread: 0, me: { ...me, ...over } };
}

describe('Meu perfil — identidade e nome', () => {
	it('mostra nome e e-mail; o campo Nome vem carregado e o Salvar começa desabilitado', () => {
		const { getByLabelText, getByRole, getAllByText } = render(Page, { props: { data: data() } });

		expect((getByLabelText(/^Nome/) as HTMLInputElement).value).toBe('Bianca Souza');
		// nome aparece no cabeçalho e como valor do input
		expect(getAllByText('Bianca Souza').length).toBeGreaterThan(0);
		expect(getByRole('button', { name: 'Salvar' })).toBeDisabled();
	});

	it('o e-mail é somente leitura (não editável aqui)', () => {
		const { getByLabelText } = render(Page, { props: { data: data() } });
		const email = getByLabelText('E-mail') as HTMLInputElement;
		expect(email.value).toBe('bianca@ex.com');
		expect(email).toBeDisabled();
	});

	it('digitar um nome diferente habilita o Salvar; em branco mantém desabilitado', async () => {
		const { getByLabelText, getByRole } = render(Page, { props: { data: data() } });
		const nome = getByLabelText(/^Nome/);

		await fireEvent.input(nome, { target: { value: 'Bianca F. Souza' } });
		expect(getByRole('button', { name: 'Salvar' })).toBeEnabled();

		await fireEvent.input(nome, { target: { value: '   ' } });
		expect(getByRole('button', { name: 'Salvar' })).toBeDisabled();
	});
});

describe('Meu perfil — clínicas', () => {
	it('lista as clínicas do usuário e marca a ativa', () => {
		const { getByText, getAllByText } = render(Page, { props: { data: data() } });

		expect(getByText('Clínica Vida')).toBeInTheDocument();
		expect(getByText('Clínica Sul')).toBeInTheDocument();
		// só a clínica ativa recebe o selo "Ativa".
		expect(getAllByText('Ativa')).toHaveLength(1);
	});
});

describe('Meu perfil — sair de todos os dispositivos', () => {
	it('o botão abre a confirmação e o form aponta para /auth/sign-out-everywhere', async () => {
		const { getByRole, getByText, container } = render(Page, { props: { data: data() } });

		const form = container.querySelector('form[action="/auth/sign-out-everywhere"]');
		expect(form).toBeTruthy();
		expect((form as HTMLFormElement).method).toBe('post');

		await fireEvent.click(getByRole('button', { name: /Sair de todos os dispositivos/ }));
		// o callout destrutivo da confirmação aparece (texto único do diálogo).
		expect(getByText(/precisará entrar de novo/)).toBeInTheDocument();
		expect(getByRole('button', { name: 'Sair de tudo' })).toBeInTheDocument();
	});
});
