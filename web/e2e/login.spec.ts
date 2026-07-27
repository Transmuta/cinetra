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
