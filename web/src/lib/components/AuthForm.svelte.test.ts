import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

// Módulos virtuais do SvelteKit que o AuthForm usa (enhance + page atual).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));
vi.mock('$app/state', () => ({ page: { url: { pathname: '/entrar' } } }));

import AuthForm from './AuthForm.svelte';

const baseProps = { submitLabel: 'Enviar link de acesso', googleLabel: 'Entrar com Google' };

describe('AuthForm', () => {
	it('estado neutro (form.sent): confirma sem formulário e ecoa o e-mail', () => {
		const { getByText, queryByRole } = render(AuthForm, {
			props: { ...baseProps, form: { sent: true, email: 'ana@x.com' } }
		});

		expect(getByText('Confira seu e-mail')).toBeInTheDocument();
		expect(getByText('ana@x.com')).toBeInTheDocument();
		// Sem formulário: nada de botão de envio no estado neutro.
		expect(queryByRole('button')).toBeNull();
	});

	it('estado inicial (form null): campo de e-mail, botão de envio e link do Google', () => {
		const { getByLabelText, getByRole } = render(AuthForm, {
			props: { ...baseProps, form: null }
		});

		expect(getByLabelText('E-mail')).toBeInTheDocument();
		expect(getByRole('button', { name: 'Enviar link de acesso' })).toBeInTheDocument();

		const google = getByRole('link', { name: 'Entrar com Google' });
		expect(google).toHaveAttribute('href', '/auth/google');
		// /auth/google é endpoint +server (sem +page): sem reload, o clique 404a no client router.
		expect(google).toHaveAttribute('data-sveltekit-reload');
	});

	it('clicar no Google sinaliza carregamento (feedback de autenticação em curso)', async () => {
		const { getByRole, getByText } = render(AuthForm, { props: { ...baseProps, form: null } });

		await fireEvent.click(getByRole('link', { name: 'Entrar com Google' }));

		// O botão troca o rótulo para o estado de carregando enquanto o browser navega ao Google.
		expect(getByText('Conectando…')).toBeInTheDocument();
	});

	it('erro de validação: exibe a mensagem retornada pela action', () => {
		const { getByText } = render(AuthForm, {
			props: { ...baseProps, form: { error: 'Informe seu e-mail.' } }
		});

		expect(getByText('Informe seu e-mail.')).toBeInTheDocument();
	});

	it('sem collectName (login): não renderiza campo de nome', () => {
		const { queryByLabelText, getByLabelText } = render(AuthForm, {
			props: { ...baseProps, form: null }
		});

		expect(getByLabelText('E-mail')).toBeInTheDocument();
		expect(queryByLabelText('Nome')).toBeNull();
	});

	it('collectName (cadastro): renderiza campo de nome e ecoa o valor no erro', () => {
		const { getByLabelText } = render(AuthForm, {
			props: { ...baseProps, collectName: true, form: { nome: 'Ana', error: 'Informe seu e-mail.' } }
		});

		const nome = getByLabelText('Nome') as HTMLInputElement;
		expect(nome).toBeInTheDocument();
		expect(nome).toBeRequired();
		expect(nome.value).toBe('Ana');
	});
});
