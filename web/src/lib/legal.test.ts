import { describe, it, expect } from 'vitest';
import { DOCUMENTOS, PRIVACIDADE, TERMOS, EMPRESA, ATUALIZACAO, textoDe } from './legal';

// Os dois documentos legais são DADO, não markup (a mesma escolha do `FAQ` em `seo.ts`): a
// página desenha o sumário e o corpo do mesmo array, então índice e texto não têm como divergir.
// Estes testes guardam as invariantes que ninguém revisa a olho num texto de 3 mil palavras.

describe('documentos legais', () => {
	it('publica exatamente os dois documentos, cada um na sua rota', () => {
		expect(DOCUMENTOS.map((d) => d.caminho)).toEqual(['/privacidade', '/termos']);
		expect(DOCUMENTOS).toEqual([PRIVACIDADE, TERMOS]);
	});

	for (const doc of DOCUMENTOS) {
		describe(doc.titulo, () => {
			it('cada seção tem id único (é a chave do {#each} e a âncora do sumário)', () => {
				const ids = doc.secoes.map((s) => s.id);
				expect(new Set(ids).size).toBe(ids.length);
			});

			it('nenhuma seção fica sem conteúdo, e nenhuma lista fica vazia', () => {
				for (const secao of doc.secoes) {
					expect(secao.blocos.length, secao.id).toBeGreaterThan(0);
					for (const bloco of secao.blocos) {
						if (typeof bloco === 'string') expect(bloco.length, secao.id).toBeGreaterThan(40);
						else expect(bloco.lista.length, secao.id).toBeGreaterThan(1);
					}
				}
			});

			// Texto puro, como as respostas do FAQ: a página renderiza cada bloco como parágrafo ou
			// item de lista, e HTML solto no dado viraria markup escapado na tela.
			it('nenhum bloco carrega HTML', () => {
				expect(textoDe(doc)).not.toMatch(/<[a-z/]/i);
			});

			// Mesma preferência de escrita já cobrada no FAQ (seo.ts): a copy do projeto não usa
			// travessão. Texto legal é justamente onde ele reaparece sozinho.
			it('a copy não usa travessão', () => {
				expect(textoDe(doc)).not.toContain('—');
			});

			it('tem descrição própria para o <head>, dentro do corte do buscador', () => {
				expect(doc.descricao.length).toBeGreaterThan(60);
				expect(doc.descricao.length).toBeLessThanOrEqual(160);
			});

			it('abre dizendo desde quando vale', () => {
				expect(doc.atualizacao).toBe(ATUALIZACAO);
			});

			// Um documento legal sem como falar com o controlador não serve ao art. 9º da LGPD.
			it('traz o contato de privacidade em alguma seção', () => {
				expect(textoDe(doc)).toContain(EMPRESA.emailPrivacidade);
			});

			it('aponta para o outro documento (quem lê um precisa achar o par)', () => {
				const par = DOCUMENTOS.find((d) => d !== doc)!;
				expect(doc.par).toBe(par.caminho);
			});
		});
	}

	// Os dados do controlador ainda não existem (decisão de 2026-07-29: entram antes de publicar).
	// O marcador é visível de propósito, e este teste é o que impede alguém de inventar um CNPJ
	// para "fechar" o texto: enquanto o placeholder estiver lá, ele está declarado aqui.
	it('os dados do controlador estão marcados como pendentes, nunca inventados', () => {
		for (const campo of [EMPRESA.razaoSocial, EMPRESA.cnpj, EMPRESA.endereco, EMPRESA.foro]) {
			expect(campo).toMatch(/^\[.+\]$/);
		}
		// CNPJ inventado é o erro que este teste existe para pegar.
		expect(EMPRESA.cnpj).not.toMatch(/\d/);
	});

	// 2026-08-06, achado ao investigar por que TODO e-mail estava caindo no spam. Os dois contatos
	// eram `@cinetra.app` — domínio que NUNCA foi registrado (NXDOMAIN, sem SOA nem NS). Num
	// documento que o art. 9º da LGPD obriga a trazer um canal com o controlador, isso é um canal
	// que não existe: quem exercesse um direito escreveria para o vazio.
	//
	// O par no backend é `Api.Accounts.Emails.@contato`, com o teste gêmeo em
	// `api/test/api/accounts/emails_test.exs` ("endereço de contato").
	it('os contatos são de um domínio que existe e recebe e-mail', () => {
		for (const email of [EMPRESA.emailPrivacidade, EMPRESA.emailContato]) {
			expect(email).toMatch(/@cinetra\.com\.br$/);
			expect(email).not.toContain('cinetra.app');
		}
	});

	it('a política de privacidade separa os dois papéis (controladora e operadora)', () => {
		const texto = textoDe(PRIVACIDADE).toLowerCase();
		expect(texto).toContain('operadora');
		expect(texto).toContain('controladora');
	});

	it('os termos dizem que a Cinetra não presta serviço de saúde', () => {
		expect(textoDe(TERMOS).toLowerCase()).toContain('não presta serviço de saúde');
	});
});
