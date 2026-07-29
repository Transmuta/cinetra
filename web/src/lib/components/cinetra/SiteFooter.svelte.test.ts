import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import SiteFooter from './SiteFooter.svelte';
import { DOCUMENTOS } from '$lib/legal';

describe('SiteFooter (rodapé das páginas públicas)', () => {
	// O rodapé é o único lugar em que os documentos legais são alcançáveis a partir de qualquer
	// página pública. Perder este link é perder as duas páginas.
	it('leva aos dois documentos legais', () => {
		const { getByRole } = render(SiteFooter);

		for (const doc of DOCUMENTOS) {
			expect(getByRole('link', { name: doc.titulo })).toHaveAttribute('href', doc.caminho);
		}
	});

	// O rodapé aparece TAMBÉM nas páginas legais, onde `#precos` não existe: as âncoras do rodapé
	// são sempre absolutas, ao contrário das do topo, que a landing usa relativas.
	it('as âncoras de seção passam pela home, para funcionarem de qualquer página', () => {
		const { getByRole } = render(SiteFooter);

		expect(getByRole('link', { name: /recursos/i })).toHaveAttribute('href', '/#recursos');
		expect(getByRole('link', { name: /planos/i })).toHaveAttribute('href', '/#precos');
	});

	it('mantém o gancho de layout do mobile (cn-footrow)', () => {
		const { container } = render(SiteFooter);
		expect(container.querySelector('.cn-footrow')).not.toBeNull();
	});
});
