import { describe, it, expect, vi } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent, cleanup } from '@testing-library/svelte';
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

	// `loading` virou `emVoo` — o mesmo nome que `forms.svelte.ts` e `SubmitButton` já usavam.
	// Um conceito com dois nomes no mesmo repositório é meio caminho para dois comportamentos.
	it('emVoo: link fica aria-busy e sem pointer events (evita duplo-clique)', () => {
		const { getByRole } = render(Button, {
			props: { href: '/auth/google', emVoo: true, children: label('Google') }
		});
		const link = getByRole('link', { name: 'Google' });
		expect(link).toHaveAttribute('aria-busy', 'true');
		expect(link.className).toContain('pointer-events-none');
	});

	/**
	 * O eixo que o `SubmitButton` já cobria e que o `Button` não tinha: um botão só APAGADO
	 * parece quebrado e convida ao segundo clique — onde a ação não é idempotente (converter uma
	 * vaga, aplicar massa num pacote), o segundo POST volta como conflito contra o primeiro.
	 */
	it('emVoo: o botão trava, anuncia e MOSTRA o giro', () => {
		const { getByRole, container } = render(Button, {
			props: { emVoo: true, children: label('Salvar') }
		});
		const btn = getByRole('button');

		expect(btn).toBeDisabled();
		expect(btn).toHaveAttribute('aria-busy', 'true');
		expect(container.querySelector('.animate-spin')).toBeInTheDocument();
	});

	it('encaminha onclick ao clicar', async () => {
		const onclick = vi.fn();
		const { getByRole } = render(Button, { props: { onclick, children: label('Ir') } });
		await fireEvent.click(getByRole('button', { name: 'Ir' }));
		expect(onclick).toHaveBeenCalledOnce();
	});

	it('fica desabilitado com disabled', () => {
		const { getByRole } = render(Button, {
			props: { disabled: true, children: label('Enviando…') }
		});
		expect(getByRole('button')).toBeDisabled();
	});

	/**
	 * Eram 23 instâncias primárias em 15 grafias, variando padding, fonte, hover (quatro sem
	 * nenhum) e desabilitado (doc 93 §M-4). O que este bloco trava não é a estética das classes —
	 * é que as decisões passem a ser as MESMAS quatro para todo mundo.
	 */
	describe('variantes', () => {
		// Limpa antes de cada render: sem isso os botões se acumulam no mesmo container e o
		// `getByRole` acha vários.
		const classe = (props: Record<string, unknown>) => {
			cleanup();
			return render(Button, { props: { ...props, children: label('x') } }).getByRole('button')
				.className;
		};

		it('primária é o sage com o seu par de texto e tem hover', () => {
			const c = classe({ variant: 'primary' });
			expect(c).toContain('bg-primary');
			expect(c).toContain('text-on-primary');
			expect(c).toContain('hover:bg-primary-hover');
		});

		it('destrutiva usa o vermelho ESCURECIDO — o que faz o branco passar', () => {
			expect(classe({ variant: 'danger' })).toContain('bg-danger-solid');
		});

		it('secundária tem borda e superfície, não fundo sólido', () => {
			const c = classe({ variant: 'secondary' });
			expect(c).toContain('border-edge');
			expect(c).not.toContain('bg-primary');
		});

		it('os dois tamanhos diferem, e ambos vêm da escala', () => {
			expect(classe({ size: 'sm' })).toContain('text-rotulo');
			expect(classe({ size: 'md' })).toContain('text-corpo');
		});

		/** A causa do componente ter sido usado uma vez só: ele NASCIA `w-full`. */
		it('não impõe largura — quem sabe se preenche a linha é o chamador', () => {
			expect(classe({})).not.toContain('w-full');
			expect(classe({ class: 'w-full' })).toContain('w-full');
		});

		it('toda variante tem transição — nenhuma das 15 grafias antigas tinha', () => {
			for (const variant of ['primary', 'secondary', 'ghost', 'danger'] as const) {
				expect(classe({ variant })).toContain('transition-colors');
			}
		});
	});
});
