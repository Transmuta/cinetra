import { test, expect } from '@playwright/test';

// Os dois documentos legais. Precisa de e2e pela mesma razão da landing (`home.spec.ts`): o
// layout deles é media query pura, e o jsdom do Vitest não aplica CSS nem tem viewport. O teste
// de componente garante o HTML (sumário, âncoras, hierarquia); a geometria é aqui.
const DOCUMENTOS = ['/privacidade', '/termos'];

test.describe('Documentos legais no mobile', () => {
	for (const caminho of DOCUMENTOS) {
		// 320px é o piso (iPhone SE 1); 390px é o celular típico. Texto longo é onde transbordo
		// horizontal aparece primeiro, porque basta uma palavra que não quebra.
		for (const largura of [320, 390]) {
			test(`${caminho} a ${largura}px: nada transborda na horizontal`, async ({ page }) => {
				await page.setViewportSize({ width: largura, height: 844 });
				await page.goto(caminho);

				const { scroll, tela } = await page.evaluate(() => ({
					scroll: document.documentElement.scrollWidth,
					tela: window.innerWidth
				}));
				expect(scroll).toBe(tela);
			});
		}

		test(`${caminho}: o sumário deixa de grudar quando empilha`, async ({ page }) => {
			await page.setViewportSize({ width: 390, height: 844 });
			await page.goto(caminho);

			// `sticky` num sumário de 14 itens numa tela de 390px ocuparia a janela inteira e
			// ficaria por cima da leitura. Empilhado, ele é um bloco comum no topo do texto.
			const sumario = page.locator('.cn-sumario');
			expect(await sumario.evaluate((el) => getComputedStyle(el).position)).toBe('static');

			// E o texto começa DEPOIS dele, e não ao lado: a coluna colapsou de verdade.
			const [caixaSumario, caixaTexto] = await Promise.all([
				sumario.boundingBox(),
				page.locator('.cn-legal').boundingBox()
			]);
			expect(caixaTexto!.y).toBeGreaterThan(caixaSumario!.y + caixaSumario!.height - 1);
		});
	}
});

test.describe('Documentos legais no desktop', () => {
	test('o sumário gruda ao lado do texto, e cada âncora acha a sua seção', async ({ page }) => {
		await page.setViewportSize({ width: 1280, height: 900 });
		await page.goto('/privacidade');

		const sumario = page.locator('.cn-sumario');
		expect(await sumario.evaluate((el) => getComputedStyle(el).position)).toBe('sticky');

		// Duas colunas: o texto começa à direita do sumário, na mesma altura.
		const [caixaSumario, caixaTexto] = await Promise.all([
			sumario.boundingBox(),
			page.locator('.cn-legal').boundingBox()
		]);
		expect(caixaTexto!.x).toBeGreaterThan(caixaSumario!.x + caixaSumario!.width);

		// Âncora quebrada é o defeito clássico de documento legal com índice. Aqui ela é provada
		// no browser, não só no HTML.
		const alvos = await page
			.locator('.cn-sumario a')
			.evaluateAll((links) =>
				links.map((a) => Boolean(document.querySelector(a.getAttribute('href')!)))
			);
		expect(alvos.length).toBeGreaterThan(5);
		expect(alvos.every(Boolean)).toBe(true);
	});

	// O topo é sticky: sem `scroll-margin-top` a âncora para o título embaixo da barra.
	test('a âncora não esconde o título embaixo do topo fixo', async ({ page }) => {
		await page.setViewportSize({ width: 1280, height: 900 });
		await page.goto('/privacidade#retencao');

		const barra = (await page.getByRole('banner').boundingBox())!;
		const titulo = (await page.locator('#retencao h2').boundingBox())!;
		expect(titulo.y).toBeGreaterThanOrEqual(barra.y + barra.height);
	});
});

test.describe('Alcance dos documentos', () => {
	test('o rodapé da landing leva aos dois', async ({ page }) => {
		await page.goto('/');

		const rodape = page.getByRole('contentinfo');
		await rodape.getByRole('link', { name: 'Política de Privacidade' }).click();
		await expect(page).toHaveURL(/\/privacidade$/);
		await expect(page.getByRole('heading', { level: 1 })).toHaveText('Política de Privacidade');
	});

	test('do cadastro se chega aos dois documentos, e de volta', async ({ page }) => {
		await page.goto('/criar-conta');

		await page.getByRole('link', { name: 'Termos de Uso' }).click();
		await expect(page).toHaveURL(/\/termos$/);
		await expect(page.getByRole('heading', { level: 1 })).toHaveText('Termos de Uso');
	});
});
