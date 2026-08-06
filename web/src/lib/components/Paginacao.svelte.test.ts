import { describe, it, expect, vi, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import userEvent from '@testing-library/user-event';

import Paginacao from './Paginacao.svelte';
import type { PageInfo } from '$lib/pagination';

afterEach(cleanup);

const pagina = (over: Partial<PageInfo> = {}): PageInfo => ({
	limit: 50,
	offset: 0,
	total: 214,
	more: true,
	...over
});

function montar(over: Record<string, unknown> = {}) {
	const onPage = vi.fn();
	render(Paginacao, { current: 1, pageInfo: pagina(), onPage, ...over });
	return { onPage };
}

const anterior = () => screen.getByRole('button', { name: /anterior/i });
const proxima = () => screen.getByRole('button', { name: /próxima/i });

describe('Paginacao', () => {
	/** Uma lista que cabe numa página não ganha cromo — era o `{#if}` repetido nas quatro cópias. */
	it('some quando só há uma página', () => {
		montar({ current: 1, pageInfo: pagina({ more: false }) });

		expect(screen.queryByRole('navigation')).not.toBeInTheDocument();
	});

	it('aparece na última página, para dar o caminho de volta', () => {
		montar({ current: 3, pageInfo: pagina({ more: false }) });

		expect(screen.getByRole('navigation')).toBeInTheDocument();
	});

	it('navega para trás e para frente a partir da página atual', async () => {
		const { onPage } = montar({ current: 2 });

		await userEvent.click(anterior());
		expect(onPage).toHaveBeenCalledWith(1);

		await userEvent.click(proxima());
		expect(onPage).toHaveBeenCalledWith(3);
	});

	it('"Anterior" morre na primeira página e "Próxima" quando não há mais', () => {
		montar({ current: 1, pageInfo: pagina({ more: true }) });
		expect(anterior()).toBeDisabled();
		expect(proxima()).toBeEnabled();

		cleanup();

		montar({ current: 4, pageInfo: pagina({ more: false }) });
		expect(anterior()).toBeEnabled();
		expect(proxima()).toBeDisabled();
	});

	describe('o rótulo', () => {
		it('aparece quando a tela sabe o total', () => {
			montar({ rotulo: '1–50 de 214' });

			expect(screen.getByText('1–50 de 214')).toBeInTheDocument();
		});

		/**
		 * `/notificacoes` passa `null` de propósito: a API do sino não conta o total porque contar
		 * obriga a ler o recorte inteiro. A ausência é decisão, e a prop a torna legível.
		 */
		it('some quando a API não conta o total — e os botões continuam lá', () => {
			montar({ rotulo: null });

			expect(screen.getByRole('navigation')).toBeInTheDocument();
			expect(proxima()).toBeInTheDocument();
		});
	});

	it('tem nome acessível — é navegação, não um par de botões soltos', () => {
		montar();

		expect(screen.getByRole('navigation')).toHaveAccessibleName('Paginação');
	});
});
