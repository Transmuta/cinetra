import { describe, it, expect } from 'vitest';
import '@testing-library/jest-dom/vitest';
import { render } from '@testing-library/svelte';
import LegalPage from './LegalPage.svelte';
import { PRIVACIDADE, TERMOS, VERSAO } from '$lib/legal';

const dados = { canonical: 'https://cinetra.app/privacidade', origem: 'https://cinetra.app' };
const desenha = (doc = PRIVACIDADE) => render(LegalPage, { props: { doc, ...dados } });

describe('LegalPage (casca dos documentos legais)', () => {
	it('o título do documento é o h1 da página', () => {
		const { getByRole } = desenha();
		expect(getByRole('heading', { level: 1, name: PRIVACIDADE.titulo })).toBeInTheDocument();
	});

	it('diz desde quando o texto vale, e em que versão', () => {
		const { getByText } = desenha();
		expect(getByText(new RegExp(PRIVACIDADE.atualizacao))).toBeInTheDocument();
		expect(getByText(new RegExp(`vers[ãa]o ${VERSAO}`, 'i'))).toBeInTheDocument();
	});

	// O sumário e o corpo saem do MESMO array (é a razão de o documento ser dado e não markup).
	// Este teste é o que prova que continuam saindo: um índice que aponta para âncora inexistente
	// é o defeito clássico de documento legal, e ninguém o percebe lendo a página.
	it('o sumário lista todas as seções, e cada âncora existe no corpo', () => {
		const { container, getByRole } = desenha();

		for (const secao of PRIVACIDADE.secoes) {
			expect(getByRole('link', { name: secao.titulo })).toHaveAttribute('href', `#${secao.id}`);
			expect(container.querySelector(`#${secao.id}`)).not.toBeNull();
		}
	});

	it('cada seção é um h2 de verdade (navegação por títulos)', () => {
		const { getAllByRole } = desenha();
		const h2 = getAllByRole('heading', { level: 2 }).map((h) => h.textContent?.trim());

		for (const secao of PRIVACIDADE.secoes) expect(h2).toContain(secao.titulo);
	});

	it('a hierarquia de títulos não salta nível', () => {
		const { getAllByRole } = desenha();
		const niveis = getAllByRole('heading').map((h) => Number(h.tagName[1]));

		expect(niveis.filter((n) => n === 1)).toHaveLength(1);
		expect(niveis[0]).toBe(1);
		niveis.forEach((nivel, i) => {
			if (i > 0) expect(nivel - niveis[i - 1]).toBeLessThanOrEqual(1);
		});
	});

	it('bloco de lista vira lista de verdade, não parágrafo com marcador', () => {
		const { container } = desenha();
		const itens = [...container.querySelectorAll('.cn-legal li')].map((li) => li.textContent);
		const primeiraLista = PRIVACIDADE.secoes.flatMap((s) =>
			s.blocos.filter((b) => typeof b !== 'string')
		)[0] as { lista: readonly string[] };

		expect(itens).toContain(primeiraLista.lista[0]);
	});

	it('leva ao documento par (quem lê um precisa achar o outro)', () => {
		const { getAllByRole } = desenha();
		const hrefs = getAllByRole('link').map((a) => a.getAttribute('href'));
		expect(hrefs).toContain(TERMOS.caminho);
	});

	it('veste o chrome público: topo, rodapé e landmark de conteúdo', () => {
		const { container, getByRole } = desenha();

		expect(container.querySelector('.cn-topbar')).not.toBeNull();
		expect(container.querySelector('.cn-footrow')).not.toBeNull();
		expect(getByRole('main')).toBeInTheDocument();
		expect(container.querySelector('a.cn-skip')).toHaveAttribute('href', '#conteudo');
	});

	it('serve os dois documentos com a mesma casca', () => {
		const { getByRole } = desenha(TERMOS);
		expect(getByRole('heading', { level: 1, name: TERMOS.titulo })).toBeInTheDocument();
		expect(getByRole('heading', { level: 2, name: TERMOS.secoes[0].titulo })).toBeInTheDocument();
	});
});
