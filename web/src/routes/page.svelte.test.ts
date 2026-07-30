import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render, fireEvent } from '@testing-library/svelte';
import Page from './+page.svelte';
import { FAQ } from '$lib/seo';

// A landing recebe do servidor a canônica e a origem (dependem do ORIGIN, doc 57).
const data = { canonical: 'https://cinetra.app/', origem: 'https://cinetra.app' };
const renderLanding = () => render(Page, { props: { data } });

describe('landing /', () => {
	it('a headline principal aparece', () => {
		const { getByRole } = renderLanding();
		expect(getByRole('heading', { name: /cuida de si mesma/i })).toBeInTheDocument();
	});

	it('os CTAs apontam para criar conta e entrar', () => {
		const { getAllByRole } = renderLanding();
		const hrefs = getAllByRole('link').map((a) => a.getAttribute('href'));
		expect(hrefs).toContain('/criar-conta');
		expect(hrefs).toContain('/entrar');
	});

	it('o toggle de cobrança troca o preço exibido (anual → mensal)', async () => {
		const { getByText } = renderLanding();
		// Anual por padrão: plano Clínica R$ 289.
		expect(getByText(/289/)).toBeInTheDocument();

		await fireEvent.click(getByText('Mensal'));
		// Mensal: plano Clínica R$ 349.
		expect(getByText(/349/)).toBeInTheDocument();
	});

	it('o toggle diz ao leitor de tela QUAL periodicidade está valendo', async () => {
		const { getByRole } = renderLanding();
		const anual = getByRole('button', { name: /anual/i });
		const mensal = getByRole('button', { name: /mensal/i });

		expect(anual).toHaveAttribute('aria-pressed', 'true');
		expect(mensal).toHaveAttribute('aria-pressed', 'false');

		await fireEvent.click(mensal);
		expect(mensal).toHaveAttribute('aria-pressed', 'true');
		expect(anual).toHaveAttribute('aria-pressed', 'false');
	});

	it('a hierarquia de títulos é contínua: um h1, e nenhum salto de nível', () => {
		const { getAllByRole } = renderLanding();
		const niveis = getAllByRole('heading').map((h) => Number(h.tagName[1]));

		expect(niveis.filter((n) => n === 1)).toHaveLength(1);
		expect(niveis[0]).toBe(1);
		// Descer mais de um nível de uma vez (h2 → h4) quebra a navegação por títulos.
		niveis.forEach((nivel, i) => {
			if (i > 0) expect(nivel - niveis[i - 1]).toBeLessThanOrEqual(1);
		});
	});

	it('as três dores são subtítulos de verdade (h3), não texto grande', () => {
		const { getByRole } = renderLanding();
		for (const titulo of [/agenda vive em três lugares/i, /cada falta é um buraco/i, /pacote acaba/i]) {
			expect(getByRole('heading', { level: 3, name: titulo })).toBeInTheDocument();
		}
	});

	it('tem landmark main e atalho de teclado para ele', () => {
		const { getByRole, container } = renderLanding();
		expect(getByRole('main')).toBeInTheDocument();
		expect(container.querySelector('a.cn-skip')).toHaveAttribute('href', '#conteudo');
	});
});

describe('landing / — seção de dúvidas', () => {
	it('desenha todas as perguntas do FAQ, como títulos', () => {
		const { getByRole } = renderLanding();
		for (const { pergunta } of FAQ) {
			expect(getByRole('heading', { level: 3, name: pergunta })).toBeInTheDocument();
		}
	});

	// O que o buscador (e quem usa leitor de tela) lê tem de estar no HTML mesmo fechado — é a
	// razão de ser `<details>` nativo e não uma sanfona que só monta o texto ao clicar.
	it('as respostas estão no HTML mesmo com o item fechado', () => {
		const { container, getByText } = renderLanding();
		const fechados = [...container.querySelectorAll('.cn-faq details')].filter(
			(d) => !(d as HTMLDetailsElement).open
		);

		expect(fechados.length).toBe(FAQ.length - 1);
		for (const { resposta } of FAQ) expect(getByText(resposta)).toBeInTheDocument();
	});

	it('o primeiro item abre por padrão e o resto começa fechado', () => {
		const { container } = renderLanding();
		const abertos = [...container.querySelectorAll('.cn-faq details')].map(
			(d) => (d as HTMLDetailsElement).open
		);

		expect(abertos[0]).toBe(true);
		expect(abertos.slice(1).every((a) => !a)).toBe(true);
	});

	it('a navegação leva à seção', () => {
		const { getAllByRole } = renderLanding();
		const hrefs = getAllByRole('link').map((a) => a.getAttribute('href'));
		expect(hrefs).toContain('#duvidas');
	});

	it('mantém os ganchos que o mobile usa', () => {
		const { container } = renderLanding();

		// Só a presença das classes: quem muda o layout são as media queries de cinetra.css, e o
		// jsdom não aplica CSS — o comportamento está em `e2e/home.spec.ts`. Isto aqui é o pedaço
		// que roda no CI, para um refactor não levar a regra junto sem ninguém perceber.
		expect(container.querySelector('.cn-landing')).not.toBeNull();
		expect(container.querySelector('.cn-topbar')).not.toBeNull();
		expect(container.querySelector('.cn-footrow')).not.toBeNull();
		expect(container.querySelector('.cn-quote')).not.toBeNull();

		// Um `.cn-wrap` para cada wrapper interno de `.cn-sect` — é o que evita a calha dobrada.
		expect(container.querySelectorAll('.cn-wrap').length).toBe(7);
	});
});
