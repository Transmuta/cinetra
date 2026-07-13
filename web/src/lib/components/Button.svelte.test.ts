import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';
import Button from './Button.svelte';

// Snippet mínimo para o slot `children`.
const label = (text: string) =>
	createRawSnippet(() => ({ render: () => `<span>${text}</span>` }));

describe('Button', () => {
	it('renderiza um <button> por padrão', () => {
		const { getByRole } = render(Button, { props: { type: 'submit', children: label('Enviar') } });
		const btn = getByRole('button', { name: 'Enviar' });
		expect(btn).toHaveAttribute('type', 'submit');
	});

	it('vira um link <a> quando recebe href', () => {
		const { getByRole } = render(Button, {
			props: { href: '/auth/google', children: label('Google') }
		});
		expect(getByRole('link', { name: 'Google' })).toHaveAttribute('href', '/auth/google');
	});

	it('com reload, marca o link com data-sveltekit-reload (força navegação completa)', () => {
		// Endpoints +server (sem +page) 404am na navegação client-side do SvelteKit; o
		// data-sveltekit-reload força um GET completo do browser, que bate no endpoint.
		const { getByRole } = render(Button, {
			props: { href: '/auth/google', reload: true, children: label('Google') }
		});
		expect(getByRole('link', { name: 'Google' })).toHaveAttribute('data-sveltekit-reload');
	});

	it('sem reload, o link NÃO tem data-sveltekit-reload', () => {
		const { getByRole } = render(Button, {
			props: { href: '/dashboard', children: label('Ir') }
		});
		expect(getByRole('link', { name: 'Ir' })).not.toHaveAttribute('data-sveltekit-reload');
	});

	it('fica desabilitado com disabled', () => {
		const { getByRole } = render(Button, {
			props: { disabled: true, children: label('Enviando…') }
		});
		expect(getByRole('button')).toBeDisabled();
	});
});
