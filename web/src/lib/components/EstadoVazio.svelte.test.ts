import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';

import CircleOff from '@lucide/svelte/icons/circle-off';
import EstadoVazio from './EstadoVazio.svelte';
import Hospedeiro from './EstadoVazio.hospedeiro.test.svelte';

afterEach(cleanup);

describe('EstadoVazio', () => {
	it('mostra o título que o chamador deu', () => {
		render(EstadoVazio, { icone: CircleOff, titulo: 'Nenhuma alteração registrada' });

		expect(screen.getByText('Nenhuma alteração registrada')).toBeInTheDocument();
	});

	/**
	 * Descrição e ação são opcionais porque nem todo vazio tem saída — `/auditoria` sem filtro só
	 * constata. O que NÃO pode faltar é o título: um vazio sem dizer qual vazio mente (a lição que
	 * o `AgendaEmptyState` registrou, doc 94 §2.4).
	 */
	it('sem descrição e sem ação, mostra só o título', () => {
		const { container } = render(EstadoVazio, { icone: CircleOff, titulo: 'Nada aqui' });

		expect(container.querySelectorAll('p')).toHaveLength(1);
	});

	it('renderiza a descrição e a ação quando vêm', () => {
		render(Hospedeiro);

		expect(screen.getByText(/tente ampliar o período/i)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Limpar filtros' })).toBeInTheDocument();
	});

	/** `painel` é o vazio de uma TELA; `inline` é o vazio dentro de um cartão que já tem casca. */
	it('a variante decide se há casca — cartão duplo dentro de cartão é o defeito', () => {
		const { container } = render(EstadoVazio, {
			icone: CircleOff,
			titulo: 'x',
			variante: 'painel'
		});
		expect(container.firstElementChild).toHaveClass('border-edge');

		cleanup();

		const inline = render(EstadoVazio, {
			icone: CircleOff,
			titulo: 'x',
			variante: 'inline'
		});
		expect(inline.container.firstElementChild).not.toHaveClass('border-edge');
	});
});
