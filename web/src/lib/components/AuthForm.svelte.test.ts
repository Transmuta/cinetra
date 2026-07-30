import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';

// Módulos virtuais do SvelteKit que o AuthForm usa (enhance + page atual).
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy() {} }) }));
// `page.url` é uma URL de verdade, não um objeto com `pathname`: o componente também lê
// `searchParams` (o aviso de entrada que não deu certo), e o mock chapado escondia isso.
vi.mock('$app/state', () => ({ page: { url: new URL('http://localhost/entrar') } }));

import AuthForm from './AuthForm.svelte';

const baseProps = { submitLabel: 'Enviar link de acesso', googleLabel: 'Entrar com Google' };

describe('AuthForm', () => {
	it('estado neutro (form.sent): confirma sem formulário e ecoa o e-mail', () => {
		const { getByText, queryByRole } = render(AuthForm, {
			props: { ...baseProps, form: { sent: true, email: 'ana@x.com' } }
		});

		expect(getByText('Verifique seu e-mail')).toBeInTheDocument();
		expect(getByText('ana@x.com')).toBeInTheDocument();
		// Sem formulário: nada de botão de envio no estado neutro.
		expect(queryByRole('button')).toBeNull();
	});

	// A-11 (doc 88): o beco de quem se cadastrou e nunca abriu o link. Para essa pessoa o login
	// não envia nada — o `User` só nasce no consumo, e a cláusula anti-enumeração silencia o
	// envio. A tela neutra precisa apontar a saída, e a frase é fixa (não depende do e-mail),
	// que é o que a mantém compatível com o ADR-015.
	it('estado neutro do LOGIN: aponta o cadastro para quem ainda não abriu o link', () => {
		const { getByRole, getByText } = render(AuthForm, {
			props: { ...baseProps, form: { sent: true, email: 'ana@x.com' } }
		});

		expect(getByText(/Criou a conta agora e o link não chegou/)).toBeInTheDocument();
		expect(getByRole('link', { name: /Peça outro em Criar conta/ })).toHaveAttribute(
			'href',
			'/criar-conta'
		);
	});

	// No CADASTRO a mesma dica seria circular ("peça de novo onde você já está").
	it('estado neutro do CADASTRO: não repete a dica de ir ao cadastro', () => {
		const { queryByText } = render(AuthForm, {
			props: { ...baseProps, collectName: true, form: { sent: true, email: 'ana@x.com' } }
		});

		expect(queryByText(/Criou a conta agora e o link não chegou/)).toBeNull();
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

	it('sem aceite (login): não repete a nota legal, porque não se cria conta aqui', () => {
		const { queryByRole } = render(AuthForm, { props: { ...baseProps, form: null } });

		expect(queryByRole('link', { name: /termos de uso/i })).toBeNull();
		expect(queryByRole('link', { name: /política de privacidade/i })).toBeNull();
	});

	// Decisão de 2026-07-29: o aceite é NOTA, não caixa de seleção. O cadastro tem dois caminhos
	// (magic link e Google) e o Google sai da página por um `<a>`, que caixa nenhuma consegue
	// travar sem JavaScript. Uma nota que cobre os dois vale mais que um `required` que só vale
	// em um deles.
	it('aceite (cadastro): a nota leva aos dois documentos', () => {
		const { getByRole } = render(AuthForm, { props: { ...baseProps, aceite: true, form: null } });

		expect(getByRole('link', { name: /termos de uso/i })).toHaveAttribute('href', '/termos');
		expect(getByRole('link', { name: /política de privacidade/i })).toHaveAttribute(
			'href',
			'/privacidade'
		);
	});

	it('aceite: a nota diz que vale para os dois caminhos de cadastro', () => {
		const { container } = render(AuthForm, { props: { ...baseProps, aceite: true, form: null } });
		const nota = container.querySelector('[data-testid="aceite"]')!;

		expect(nota.textContent).toMatch(/google/i);
		expect(nota.textContent).toMatch(/criar.*conta|continuar/i);
	});

	// O aceite fica DEPOIS dos dois botões: é o que o cobre tanto o envio do link quanto a saída
	// para o Google. Antes do primeiro botão, ele leria como condição só do formulário.
	it('aceite: a nota vem depois do botão do Google', () => {
		const { container, getByRole } = render(AuthForm, {
			props: { ...baseProps, aceite: true, form: null }
		});
		const google = getByRole('link', { name: 'Entrar com Google' });
		const nota = container.querySelector('[data-testid="aceite"]')!;

		expect(google.compareDocumentPosition(nota) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
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
