import { describe, it, expect, afterEach } from 'vitest';
import { render, cleanup } from '@testing-library/svelte';

import Seo from './Seo.svelte';

afterEach(cleanup);

const props = {
	titulo: 'Cinetra · Gestão para clínicas de fisioterapia',
	descricao: 'Agenda, pacientes e fila de espera num lugar só.',
	canonical: 'https://cinetra.app/entrar',
	origem: 'https://cinetra.app'
};

const meta = (seletor: string) =>
	document.head.querySelector(seletor)?.getAttribute('content') ?? null;

/**
 * Estava sem teste (doc 93 §B-10), e é o componente onde a ausência de teste custa mais barato de
 * ignorar e mais caro de descobrir: nada QUEBRA quando uma tag some. O card do WhatsApp fica sem
 * imagem, a canônica aponta para outro lugar, e ninguém vê — que é exatamente a razão de as três
 * páginas públicas dividirem um componente em vez de copiarem ~15 tags cada.
 */
describe('Seo', () => {
	it('põe título, descrição e canônica no <head> do documento', () => {
		render(Seo, props);

		expect(document.title).toBe(props.titulo);
		expect(meta('meta[name="description"]')).toBe(props.descricao);
		expect(document.head.querySelector('link[rel="canonical"]')?.getAttribute('href')).toBe(
			props.canonical
		);
	});

	it('o card de rede social leva título, descrição e imagem ABSOLUTA', () => {
		render(Seo, props);

		expect(meta('meta[property="og:title"]')).toBeTruthy();
		expect(meta('meta[property="og:description"]')).toBeTruthy();

		// Relativa não funciona em card: quem renderiza é o WhatsApp, não o nosso domínio.
		const imagem = meta('meta[property="og:image"]');
		expect(imagem).toMatch(/^https?:\/\//);
	});

	it('o ogTitulo próprio ganha do título no card, quando a página tem um', () => {
		render(Seo, { ...props, ogTitulo: 'A clínica inteira numa tela' });

		expect(meta('meta[property="og:title"]')).toBe('A clínica inteira numa tela');
	});

	it('sem ogTitulo, o card cai no título — não fica vazio', () => {
		render(Seo, props);

		expect(meta('meta[property="og:title"]')).toBe(props.titulo);
	});
});
