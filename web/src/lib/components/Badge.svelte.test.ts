import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';

import Badge from './Badge.svelte';

afterEach(cleanup);

const texto = (t: string) => createRawSnippet(() => ({ render: () => `<span>${t}</span>` }));

function classe(props: Record<string, unknown> = {}): string {
	cleanup();
	const { container } = render(Badge, { props: { ...props, children: texto('x') } });
	return (container.firstElementChild as HTMLElement).className;
}

describe('Badge', () => {
	it('renderiza o conteúdo', () => {
		render(Badge, { props: { children: texto('Owner') } });

		expect(screen.getByText('Owner')).toBeInTheDocument();
	});

	it('é sempre pílula — a geometria é a coisa que os três badges NÃO compartilhavam', () => {
		expect(classe()).toContain('rounded-full');
		expect(classe({ size: 'md' })).toContain('rounded-full');
	});

	it('os dois tamanhos vêm da escala tipográfica', () => {
		expect(classe({ size: 'sm' })).toContain('text-meta');
		expect(classe({ size: 'md' })).toContain('text-rotulo');
	});

	/**
	 * As semânticas usam a própria tinta a 14% como fundo — o par que o `contraste.test.ts` mede,
	 * e a razão de `--mv-warning` e parentes serem mais escuros que o mínimo óbvio (doc 83 §5).
	 */
	it('cada tom traz o par fundo/texto junto — nunca só metade', () => {
		expect(classe({ tone: 'warning' })).toContain('bg-warning/14');
		expect(classe({ tone: 'warning' })).toContain('text-warning');

		expect(classe({ tone: 'accent' })).toContain('bg-accent-subtle');
		expect(classe({ tone: 'accent' })).toContain('text-accent-text');
	});

	/** A prioridade da fila é hex fixo (não muda no tema), então chega resolvida por `style`. */
	it('aceita cor resolvida em runtime sem abrir mão da geometria', () => {
		const { container } = render(Badge, {
			props: { style: 'background:#c3262b;color:#fff', children: texto('Urgente') }
		});
		const el = container.firstElementChild as HTMLElement;

		// jsdom normaliza o hex para `rgb()` ao aplicar o `style` — a asserção é sobre a COR que
		// chegou, não sobre a notação.
		expect(el.style.backgroundColor).toBe('rgb(195, 38, 43)');
		expect(el.className).toContain('rounded-full');
	});

	it('`max-w-full` é do componente: pílula não empurra a coluna vizinha', () => {
		expect(classe()).toContain('max-w-full');
	});
});
