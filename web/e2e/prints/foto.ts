import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { expect, type Locator, type Page } from '@playwright/test';

/**
 * O fotógrafo da central de ajuda (doc 108 §4).
 *
 * Uma função só, e propositalmente pobre: ela não sabe navegar, não sabe semear e não decide o
 * que fotografar. Quem sabe isso são os specs. O que ela garante é o que precisa ser IGUAL em
 * todas as ~70 imagens — pasta, nome, extensão e a espera antes do clique do obturador.
 *
 * ## O nome do arquivo é o id do conteúdo
 *
 * `foto(page, 'agenda-marcar-02')` grava `static/ajuda/agenda-marcar-02.png`, que é exatamente o
 * id citado no texto. É essa igualdade que permite ao gate (`ajuda.test.ts`) responder "que print
 * o texto cita e não existe?" e "que arquivo sobrou sem ninguém citar?" — as duas perguntas que
 * mantêm a página honesta ao longo do tempo.
 */
export const PASTA = resolve(import.meta.dirname, '../../static/ajuda');

export interface OpcoesFoto {
	/**
	 * Regiões a cobrir antes de fotografar. Use com parcimônia: mascarar um dado volátil evita
	 * `git diff` de imagem em toda regeneração, mas mascarar demais produz manual ilegível.
	 */
	mask?: Locator[];
	/** Espera adicional antes do disparo, para animação de entrada de modal/gaveta. */
	assentar?: number;
}

/**
 * Fotografa a página inteira ou um elemento.
 *
 * Passar um `Locator` recorta o elemento — é o caminho preferido para modal, cartão e formulário:
 * uma tela de 1440px para explicar um interruptor fica ilegível no celular, que é onde boa parte
 * da equipe lê a ajuda.
 */
export async function foto(alvo: Page | Locator, id: string, opts: OpcoesFoto = {}): Promise<void> {
	mkdirSync(PASTA, { recursive: true });

	// A fonte web só termina de carregar depois do primeiro paint; sem esperar, um punhado de
	// prints sai com a fonte de fallback — e a diferença só aparece quando a imagem já está na
	// página, lado a lado com as outras.
	// `'goto' in alvo`, e não `'evaluate' in alvo`: as DUAS coisas têm `evaluate`, então a
	// primeira forma tratava todo `Locator` como página e morria no `waitForTimeout`. `goto` só
	// existe na `Page`.
	const page = 'goto' in alvo ? (alvo as Page) : (alvo as Locator).page();
	await page.evaluate(() => document.fonts.ready);
	if (opts.assentar) await page.waitForTimeout(opts.assentar);

	await alvo.screenshot({
		path: resolve(PASTA, `${id}.png`),
		mask: opts.mask,
		maskColor: '#E6E2D8',
		animations: 'disabled',
		caret: 'hide'
	});
}

/**
 * O que a foto precisa ver antes do disparo.
 *
 * Existe para não repetir `expect(...).toBeVisible()` antes de cada `foto`, e porque a falha aqui
 * é diferente da falha de um teste: uma print tirada de uma tela ainda vazia não quebra nada — ela
 * só passa a ensinar errado, em silêncio.
 */
export async function pronto(alvo: Locator): Promise<void> {
	await expect(alvo).toBeVisible();
}
