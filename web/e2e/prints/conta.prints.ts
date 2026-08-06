import { test, expect } from '@playwright/test';
import { foto } from './foto';
import { emailUnico, entrar } from '../helpers';

// As telas públicas e o onboarding. Não usam a fixture `clinica` justamente porque o que elas
// mostram é o caminho ANTES de existir clínica — usá-la fotografaria o depois.

test('criar conta', async ({ page }) => {
	await page.goto('/criar-conta');
	await expect(page.getByRole('button', { name: 'Criar conta grátis' })).toBeVisible();
	await foto(page, 'conta-criar-01');

	// O estado neutro do envio: é o que a pessoa vê de verdade depois do clique, e é a tela que o
	// tópico precisa mostrar para explicar por que ela é sempre igual.
	await page.getByLabel('Nome').fill('Marina Prado');
	await page.getByLabel('E-mail').fill(emailUnico('print'));
	await page.getByRole('button', { name: 'Criar conta grátis' }).click();
	// Folga maior que o default: a PRIMEIRA navegação de uma sessão do `vite dev` ainda está
	// compilando a rota, e o clique pode chegar antes da hidratação — o envio acontece, mas por
	// submit nativo, com o round-trip inteiro pela frente.
	await expect(page.getByRole('heading', { name: 'Verifique seu e-mail' })).toBeVisible({
		timeout: 30_000
	});
	await foto(page, 'conta-criar-02');
});

test('entrar', async ({ page }) => {
	await page.goto('/entrar');
	await expect(page.getByRole('button', { name: 'Enviar link de acesso' })).toBeVisible();
	await foto(page, 'conta-entrar-01');
});

test('criar a clínica', async ({ page, request }) => {
	// Chega a `/comecar` pelo caminho real — conta nova, magic link consumido, ainda sem clínica.
	await entrar(page, request, emailUnico('print-onb'));
	await expect(page.getByRole('button', { name: 'Criar clínica' })).toBeVisible();
	await foto(page, 'conta-clinica-01');
});
