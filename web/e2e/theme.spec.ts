import { test, expect } from '@playwright/test';
import { emailUnico, entrar, criarClinica, stackCompleta } from './helpers';

/**
 * Contrato do dark mode sem flash (doc 03 §4.4): o toggle grava o cookie `mv-theme` e o
 * `hooks.server` re-estampa o MESMO tema no SSR do próximo request. Só um e2e prova a volta
 * inteira (cookie → SSR) — o resto é unit/integração.
 *
 * **Precisa estar autenticado**: o toggle vive no `Rail` do shell do app, e não mais nas telas de
 * entrada. Foi o que este teste descobriu ao ser rodado depois de sair do CI — ele procurava o
 * botão em `/entrar`, onde ele deixou de existir, e estourava por timeout.
 */
test('tema alterna e persiste após reload (sem flash, via cookie)', async ({ page, request }) => {
	test.skip(!(await stackCompleta(request)), 'precisa da API + banco (docker compose up)');
	test.slow();

	await entrar(page, request, emailUnico('tema'));
	await criarClinica(page, 'Clínica do Tema');

	const html = page.locator('html');

	await page.getByRole('button', { name: /Ativar tema/ }).click();

	const escolhido = await html.getAttribute('data-theme');
	expect(escolhido === 'dark' || escolhido === 'light').toBeTruthy();

	await page.reload();
	// O atributo veio já do HTML servido (SSR), não de um flash pós-hidratação.
	await expect(html).toHaveAttribute('data-theme', escolhido!);
});
