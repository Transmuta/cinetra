import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, screen, cleanup } from '@testing-library/svelte';

import StatusBadge from './StatusBadge.svelte';

afterEach(cleanup);

/**
 * Ficou de fora do `Badge` de propósito (doc 94 §2.4): ele não é pílula, é **ponto + rótulo**.
 * Forçá-lo naquele componente daria uma flag booleana que troca a geometria inteira — o
 * antipadrão que esta base não tem em lugar nenhum.
 *
 * O que ele precisa garantir é que a informação não dependa SÓ da cor do ponto: o texto diz o
 * estado por extenso, e é ele que chega a quem não distingue as duas cores.
 */
describe('StatusBadge', () => {
	it('convite pendente diz "Convite pendente", não só um ponto âmbar', () => {
		render(StatusBadge, { status: 'pendente' });

		expect(screen.getByText('Convite pendente')).toBeInTheDocument();
	});

	it('membro ativo diz "Ativo"', () => {
		render(StatusBadge, { status: 'ativo' });

		expect(screen.getByText('Ativo')).toBeInTheDocument();
	});

	it('os dois estados se distinguem também pelo tom do texto', () => {
		const { container } = render(StatusBadge, { status: 'pendente' });
		expect(container.firstElementChild?.className).toContain('text-warning');

		cleanup();

		const ativo = render(StatusBadge, { status: 'ativo' });
		expect(ativo.container.firstElementChild?.className).toContain('text-muted');
	});
});
