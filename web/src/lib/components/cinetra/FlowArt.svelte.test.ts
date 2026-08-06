import { describe, it, expect, afterEach } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, cleanup } from '@testing-library/svelte';

import FlowArt from './FlowArt.svelte';

afterEach(cleanup);

/**
 * A arte da landing, sem teste até aqui (doc 93 §B-10). O único contrato que ela tem e que quebra
 * calado é o `k`: o id do degradê é referenciado por `url(#…)` dentro do próprio SVG, e dois
 * gradientes com o MESMO id na mesma página fazem o segundo herdar as paradas do primeiro — a
 * segunda arte sai com a cor da primeira, e nada acusa.
 */
describe('FlowArt', () => {
	it('o `k` torna o id do degradê único na página', () => {
		const a = render(FlowArt, { k: 'hero' });
		const idA = a.container.querySelector('radialGradient,linearGradient')?.id;

		cleanup();

		const b = render(FlowArt, { k: 'rodape' });
		const idB = b.container.querySelector('radialGradient,linearGradient')?.id;

		expect(idA).toBeTruthy();
		expect(idB).toBeTruthy();
		expect(idA).not.toBe(idB);
	});

	it('a referência interna aponta para o id daquela instância', () => {
		const { container } = render(FlowArt, { k: 'hero' });
		const id = container.querySelector('radialGradient,linearGradient')!.id;

		expect(container.innerHTML).toContain(`url(#${id})`);
	});

	it('é decorativa: não entra na árvore de acessibilidade', () => {
		const { container } = render(FlowArt, {});
		const svg = container.querySelector('svg')!;

		expect(
			svg.getAttribute('aria-hidden') === 'true' || svg.getAttribute('role') === 'presentation'
		).toBe(true);
	});
});
