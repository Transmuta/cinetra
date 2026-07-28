import { test, expect } from '@playwright/test';

// A jornada mais crítica: entrar sem senha (ADR-015). O submit chega ao estado NEUTRO
// mesmo sem depender do e-mail chegar — a API responde neutro por design.
//
// Não precisa da stack completa: o BFF responde o estado neutro de qualquer forma (é o ponto
// do ADR-015), então estes dois rodam contra qualquer ambiente.
test.describe('Entrada passwordless', () => {
	test('/entrar: submeter e-mail leva ao estado neutro', async ({ page }) => {
		await page.goto('/entrar');
		await expect(page.getByRole('heading', { name: 'Bem-vindo de volta' })).toBeVisible();

		const email = 'teste-e2e@example.com';
		await page.getByLabel('E-mail').fill(email);
		await page.getByRole('button', { name: 'Enviar link de acesso' }).click();

		// Neutro: confirma sem revelar se a conta existe, e ecoa o e-mail informado.
		await expect(page.getByRole('heading', { name: 'Verifique seu e-mail' })).toBeVisible();
		await expect(page.getByText(email)).toBeVisible();
	});

	test('home desautenticada oferece o caminho de entrar', async ({ page }) => {
		await page.goto('/');

		// A landing tem "Entrar" no topo E no rodapé — o do topo é o caminho que interessa.
		const entrar = page.getByRole('banner').getByRole('link', { name: 'Entrar' });
		await expect(entrar).toBeVisible();

		await entrar.click();
		await expect(page).toHaveURL(/\/entrar$/);
		await expect(page.getByLabel('E-mail')).toBeVisible();
	});
});

// O split da auth some no mobile e sobra só o formulário. Precisa de e2e: a regra é uma media
// query, e nem o jsdom do Vitest aplica CSS nem haveria viewport para ela consultar.
test.describe('Auth no mobile', () => {
	test.use({ viewport: { width: 390, height: 844 } });

	test('/entrar: sem painel de marca, e o formulário ocupa a tela inteira', async ({ page }) => {
		await page.goto('/entrar');
		await expect(page.getByRole('heading', { name: 'Bem-vindo de volta' })).toBeVisible();

		// O painel de marca (o bloco navy da esquerda) não existe nesta largura.
		await expect(page.getByText('Dra. Marina Lopes')).toBeHidden();

		// E a coluna dele foi junto: o card usa a largura toda (390 − 2×28 de padding = 334).
		// Quando só o painel sumia, a coluna vazia ficava e o botão caía para 139px.
		const botao = page.getByRole('button', { name: 'Enviar link de acesso' });
		const caixa = await botao.boundingBox();
		expect(caixa?.width).toBeGreaterThan(300);

		// Nada transborda na horizontal.
		const { scroll, tela } = await page.evaluate(() => ({
			scroll: document.documentElement.scrollWidth,
			tela: window.innerWidth
		}));
		expect(scroll).toBe(tela);
	});
});
