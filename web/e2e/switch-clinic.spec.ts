import { test, expect } from '@playwright/test';
import { emailUnico, entrar, criarClinica, menuDoUsuario, stackCompleta } from './helpers';

/**
 * **I66** — o e2e que faltava: a troca de clínica ativa, com sessão de verdade.
 *
 * Por que este cenário e não outro. A troca de tenant é o ponto onde mais coisas precisam
 * concordar ao mesmo tempo — o cookie de sessão, o `Membership` ativo no servidor, o `Api.Scope`
 * que sai dele e a GUC de RLS que recorta as linhas. A suíte de unidade cobre cada peça isolada;
 * só o browser prova que, depois do POST, **a tela seguinte mostra a outra clínica**.
 *
 * A jornada é longa de propósito: criar conta → magic link → onboarding → segunda clínica →
 * trocar. Cada passo é um pedaço do encanamento que nenhum teste de unidade atravessa.
 */
test.describe('Troca de clínica ativa', () => {
	test('duas clínicas do mesmo dono: trocar muda o tenant da tela', async ({ page, request }) => {
		test.skip(!(await stackCompleta(request)), 'precisa da API + banco (docker compose up)');
		test.slow();

		const addr = emailUnico('switch');

		await entrar(page, request, addr);
		await criarClinica(page, 'Clínica Alfa');

		// Segunda clínica pelo caminho real: o link do próprio menu do usuário.
		await menuDoUsuario(page).click();
		await page.getByRole('link', { name: 'Nova clínica' }).click();
		await criarClinica(page, 'Clínica Beta');

		// Criar entra na nova: a ativa agora é a Beta.
		await menuDoUsuario(page).click();
		const ativa = page.locator('form[action="/auth/switch-clinic"] button[aria-current="true"]');
		await expect(ativa).toContainText('Clínica Beta');

		// Voltar para a Alfa — é um POST (CSRF, como o sign-out), não um link.
		await page
			.locator('form[action="/auth/switch-clinic"] button:not([aria-current="true"])')
			.first()
			.click();

		await menuDoUsuario(page).click();
		await expect(
			page.locator('form[action="/auth/switch-clinic"] button[aria-current="true"]')
		).toContainText('Clínica Alfa');
	});
});
