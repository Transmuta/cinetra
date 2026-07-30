import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import SiteHeader from './SiteHeader.svelte';

describe('SiteHeader (topo das páginas públicas)', () => {
	it('na landing, a navegação é âncora pura (rolagem na própria página)', () => {
		const { getByRole } = render(SiteHeader);
		const href = (nome: RegExp) => getByRole('link', { name: nome }).getAttribute('href');

		expect(href(/as dores/i)).toBe('#dores');
		expect(href(/recursos/i)).toBe('#recursos');
		expect(href(/planos/i)).toBe('#precos');
		expect(href(/dúvidas/i)).toBe('#duvidas');
	});

	// Fora da landing (páginas legais) a mesma âncora tem de voltar para a home antes de rolar:
	// `#precos` numa página que não tem a seção de planos é um link que não faz nada.
	it('fora da landing, a navegação volta para a home antes de rolar', () => {
		const { getByRole } = render(SiteHeader, { props: { prefixo: '/' } });

		expect(getByRole('link', { name: /planos/i })).toHaveAttribute('href', '/#precos');
		expect(getByRole('link', { name: /dúvidas/i })).toHaveAttribute('href', '/#duvidas');
	});

	it('leva à marca e mantém os dois CTAs de sempre', () => {
		const { getByRole, getAllByRole } = render(SiteHeader);

		expect(getByRole('link', { name: /página inicial/i })).toHaveAttribute('href', '/');
		const hrefs = getAllByRole('link').map((a) => a.getAttribute('href'));
		expect(hrefs).toContain('/entrar');
		expect(hrefs).toContain('/criar-conta');
	});

	it('mantém os ganchos que o mobile usa (cn-topbar, cn-navlinks)', () => {
		const { container } = render(SiteHeader);

		expect(container.querySelector('.cn-topbar')).not.toBeNull();
		expect(container.querySelector('.cn-navlinks')).not.toBeNull();
	});
});
