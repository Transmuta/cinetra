import { test, expect } from './fixtures';
import { criarPaciente } from './helpers';
import type { Page } from '@playwright/test';

/**
 * O shell do app tem **uma** área que rola: o `<main>`. O documento, nunca.
 *
 * A regressão que trouxe este arquivo: com a trilha cheia, `/auditoria` mostrava DOIS scrolls —
 * o do conteúdo e um do documento inteiro, que levava o rail, a sidebar e o topbar para fora da
 * tela. A causa não estava na página: `.sr-only` do Tailwind é `position: absolute`, e como
 * nenhum ancestral era posicionado, o **bloco container era o documento**. Cada `sr-only` lá no
 * fim de uma lista longa (na auditoria há um por linha, com a data por extenso para o leitor de
 * tela) era colocado na coordenada correspondente do DOCUMENTO — e o esticava.
 *
 * Medido no mecanismo isolado, 120 linhas com um `sr-only` cada, viewport de 800px:
 *
 *     com `sr-only`  → document.scrollHeight = 7097 (rola)   main.scrollHeight = 7080
 *     sem `sr-only`  → document.scrollHeight =  800 (não rola)
 *
 * Por isso o teste é aqui, e não em Vitest: jsdom não faz layout, então `scrollHeight` lá é
 * sempre 0 e um teste de unidade passaria verde com o bug de pé. E por isso ele mede o
 * INVARIANTE do shell (documento não rola), não a ausência de uma classe: a próxima tela longa
 * com `sr-only` reintroduziria o mesmo bug por um caminho diferente.
 */

/** O que o browser vê: o documento rola? e o `main`? */
async function medir(page: Page) {
	return page.evaluate(() => {
		const de = document.documentElement;
		const main = document.querySelector('main');
		return {
			doc: { scroll: de.scrollHeight, client: de.clientHeight },
			main: { scroll: main?.scrollHeight ?? 0, client: main?.clientHeight ?? 0 }
		};
	});
}

test('o documento não rola no shell — só o conteúdo', async ({ page, clinica }) => {
	// Viewport curta de propósito: o bug só aparece quando o conteúdo passa da tela, e assim uma
	// dúzia de linhas já basta. Nada aqui depende da altura exata.
	await page.setViewportSize({ width: 1100, height: 420 });

	// Trilha cheia: a fixture já registra clínica + profissional + paciente; estes garantem que a
	// lista passe da viewport com folga, em qualquer máquina.
	for (let i = 0; i < 12; i++) {
		await criarPaciente(clinica.api, `Paciente Scroll ${i}`);
	}

	await page.goto('/auditoria');
	await expect(page.getByRole('heading', { name: 'Auditoria', level: 2 })).toBeVisible();

	const m = await medir(page);

	// A premissa do teste: se o conteúdo não passou da tela, ele não está medindo nada.
	expect(m.main.scroll, 'a lista precisa passar da viewport para o teste valer').toBeGreaterThan(
		m.main.client
	);

	// O invariante. `scrollHeight` arredonda para cima, então 1px de folga não é o bug.
	expect(
		m.doc.scroll,
		`o documento ganhou barra de rolagem própria (${m.doc.scroll}px de conteúdo para ` +
			`${m.doc.client}px de viewport) — o shell é h-dvh, quem rola é o <main>`
	).toBeLessThanOrEqual(m.doc.client + 1);
});
