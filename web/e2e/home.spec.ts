import { test, expect } from '@playwright/test';

// A landing no celular. Precisa de e2e: são todas media queries, e nem o jsdom do Vitest aplica
// CSS nem haveria viewport para elas consultarem — o teste de componente só consegue garantir
// que os ganchos (`cn-wrap`, `cn-topbar`, …) continuam no HTML.
test.describe('Landing no mobile', () => {
	// 320px é o piso (iPhone SE 1) e onde tudo aperta; 390px é o celular típico de hoje.
	for (const largura of [320, 390]) {
		test(`${largura}px: nada transborda na horizontal`, async ({ page }) => {
			await page.setViewportSize({ width: largura, height: 844 });
			await page.goto('/');

			const { scroll, tela } = await page.evaluate(() => ({
				scroll: document.documentElement.scrollWidth,
				tela: window.innerWidth
			}));
			expect(scroll).toBe(tela);

			// O topo é sticky: se o "Começar grátis" quebrar em duas linhas, ele engorda e come
			// a tela em toda rolagem. Uma linha desse botão mede ~40px.
			const cta = page.getByRole('banner').getByRole('link', { name: 'Começar grátis' });
			const caixa = await cta.boundingBox();
			expect(caixa?.height).toBeLessThan(50);
			expect((caixa?.x ?? 0) + (caixa?.width ?? 0)).toBeLessThanOrEqual(tela);
		});
	}

	test('a calha é uma só (a seção paga, o wrapper interno não repete)', async ({ page }) => {
		await page.setViewportSize({ width: 390, height: 844 });
		await page.goto('/');

		// Antes eram 22px da seção + 30px do wrapper = 52px de cada lado, 27% da tela.
		const x = await page.locator('#dores p').first().evaluate((el) => el.getBoundingClientRect().left);
		expect(x).toBeLessThanOrEqual(24);
	});

	test('os separadores dos números viram régua horizontal quando empilham', async ({ page }) => {
		await page.setViewportSize({ width: 390, height: 844 });
		await page.goto('/');

		// No desktop o bloco do meio tem borda nas LATERAIS, separando colunas. Empilhado, aquilo
		// virava dois traços verticais soltos ao lado do "+12h".
		const meio = page.locator('.cn-num > div').nth(1);
		const bordas = await meio.evaluate((el) => {
			const cs = getComputedStyle(el);
			return { esquerda: cs.borderLeftWidth, topo: cs.borderTopWidth };
		});
		expect(bordas.esquerda).toBe('0px');
		expect(bordas.topo).toBe('1px');
	});

	test('os títulos ganham tamanho de celular', async ({ page }) => {
		await page.setViewportSize({ width: 390, height: 844 });
		await page.goto('/');

		// Só o h1 encolhia; os h2 seguiam em 44–56px e gastavam cinco linhas cada um.
		const px = await page
			.locator('#dores h2')
			.evaluate((el) => parseFloat(getComputedStyle(el).fontSize));
		expect(px).toBeLessThan(40);
	});
});

test.describe('Landing no desktop', () => {
	test('o split e as bordas de coluna seguem intactos', async ({ page }) => {
		await page.setViewportSize({ width: 1280, height: 900 });
		await page.goto('/');

		// A contraprova das regras de mobile: acima de 900px nada do que foi feito acima vale.
		const meio = page.locator('.cn-num > div').nth(1);
		expect(await meio.evaluate((el) => getComputedStyle(el).borderLeftWidth)).toBe('1px');

		const px = await page
			.locator('#dores h2')
			.evaluate((el) => parseFloat(getComputedStyle(el).fontSize));
		expect(px).toBe(52);
	});
});
