import { describe, it, expect } from 'vitest';
import { SITE, canonical, jsonLd, FAQ, PAGINAS_PUBLICAS, AREAS_PRIVADAS } from './seo';

describe('canonical (URL canônica da página)', () => {
	it('raiz: origem + barra', () => {
		expect(canonical(new URL('https://cinetra.app/'))).toBe('https://cinetra.app/');
	});

	it('descarta a query — campanha não pode virar URL canônica própria', () => {
		expect(canonical(new URL('https://cinetra.app/?utm_source=ig&utm_campaign=abr'))).toBe(
			'https://cinetra.app/'
		);
	});

	it('descarta o fragmento e a barra final (uma URL por página)', () => {
		expect(canonical(new URL('https://cinetra.app/criar-conta/#form'))).toBe(
			'https://cinetra.app/criar-conta'
		);
	});

	it('acompanha a origem do request (dev e produção pela mesma função)', () => {
		expect(canonical(new URL('http://localhost:5173/entrar'))).toBe('http://localhost:5173/entrar');
	});
});

describe('metadados da marca', () => {
	it('o título cabe no corte do buscador e carrega o termo de busca', () => {
		expect(SITE.titulo.length).toBeLessThanOrEqual(60);
		expect(SITE.titulo.toLowerCase()).toContain('fisioterapia');
	});

	it('a descrição cabe no snippet (≤160) e não é genérica', () => {
		expect(SITE.descricao.length).toBeLessThanOrEqual(160);
		expect(SITE.descricao.toLowerCase()).toContain('clínicas de fisioterapia');
	});
});

describe('jsonLd (dados estruturados)', () => {
	const grafo = jsonLd('https://cinetra.app');
	const nos = grafo['@graph'] as Array<Record<string, unknown>>;
	const tipo = (t: string) => nos.find((n) => n['@type'] === t)!;

	it('publica Organization, WebSite, SoftwareApplication e FAQPage', () => {
		expect(nos.map((n) => n['@type'])).toEqual([
			'Organization',
			'WebSite',
			'SoftwareApplication',
			'FAQPage'
		]);
	});

	it('NÃO publica nota agregada nem review — a página não tem review verificável', () => {
		const bruto = JSON.stringify(grafo);
		expect(bruto).not.toContain('aggregateRating');
		expect(bruto).not.toContain('"Review"');
	});

	it('os preços batem com o que a landing mostra ao carregar (cobrança anual)', () => {
		const ofertas = tipo('SoftwareApplication').offers as Array<Record<string, string>>;
		expect(ofertas.map((o) => [o.name, o.price, o.priceCurrency])).toEqual([
			['Profissional', '149', 'BRL'],
			['Clínica', '289', 'BRL']
		]);
	});

	it('as URLs absolutas saem da origem recebida, não de constante', () => {
		expect(tipo('WebSite').url).toBe('https://cinetra.app/');
		expect(tipo('Organization')['@id']).toBe('https://cinetra.app/#organizacao');
	});
});

describe('FAQ', () => {
	// O risco real desta marcação é divergir do texto que a pessoa lê: dado estruturado que não
	// bate com a página é motivo de ação manual do Google. As duas saem do mesmo array — este
	// teste é o que garante que continue assim se alguém montar a lista à mão amanhã.
	it('o FAQPage do JSON-LD é exatamente o array que desenha a seção', () => {
		const faqPage = (jsonLd('https://cinetra.app')['@graph'] as Array<Record<string, unknown>>).find(
			(n) => n['@type'] === 'FAQPage'
		)!;
		const perguntas = faqPage.mainEntity as Array<{
			'@type': string;
			name: string;
			acceptedAnswer: { '@type': string; text: string };
		}>;

		expect(perguntas).toHaveLength(FAQ.length);
		perguntas.forEach((q, i) => {
			expect(q['@type']).toBe('Question');
			expect(q.name).toBe(FAQ[i].pergunta);
			expect(q.acceptedAnswer['@type']).toBe('Answer');
			expect(q.acceptedAnswer.text).toBe(FAQ[i].resposta);
		});
	});

	it('cada item tem id único (é a chave do {#each} e a âncora do bloco)', () => {
		expect(new Set(FAQ.map((f) => f.id)).size).toBe(FAQ.length);
	});

	it('toda pergunta é pergunta, e nenhuma resposta é curta demais para valer conteúdo', () => {
		for (const { pergunta, resposta } of FAQ) {
			expect(pergunta.endsWith('?'), pergunta).toBe(true);
			expect(resposta.length, pergunta).toBeGreaterThan(80);
		}
	});

	// Texto puro: o schema.org escapa mal HTML aqui, e a tela renderiza como parágrafo.
	it('nenhuma resposta carrega HTML', () => {
		for (const { resposta } of FAQ) expect(resposta).not.toMatch(/<[a-z/]/i);
	});

	// Preferência de escrita do projeto, pedida em 2026-07-27: a copy não usa travessão. Vira
	// teste porque é o tipo de coisa que volta sozinha na próxima pergunta que alguém acrescentar.
	it('a copy não usa travessão', () => {
		for (const { pergunta, resposta } of FAQ) {
			expect(pergunta, pergunta).not.toContain('—');
			expect(resposta, pergunta).not.toContain('—');
		}
	});
});

describe('mapa do site', () => {
	it('a landing é a primeira e a de maior prioridade', () => {
		expect(PAGINAS_PUBLICAS[0]).toMatchObject({ caminho: '/', prioridade: '1.0' });
	});

	// Hoje o TypeScript já prova isto (as duas listas são `as const` e não têm sobreposição), mas
	// basta alguém trocar um literal por `string` para a prova sumir sem aviso — e o sintoma seria
	// uma página no sitemap que o robots manda ignorar.
	it('nenhuma página pública está bloqueada no robots (o sitemap não pode se contradizer)', () => {
		const privadas: string[] = [...AREAS_PRIVADAS];

		for (const { caminho } of PAGINAS_PUBLICAS) {
			const bloqueada = privadas.some(
				(area) => caminho === area || caminho.startsWith(`${area}/`)
			);
			expect(bloqueada, `${caminho} está no sitemap E no Disallow`).toBe(false);
		}
	});
});
