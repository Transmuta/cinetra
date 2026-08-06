import { test, expect, abrirAgenda } from './autenticado';
import { foto } from './foto';
import { criarAgendamento, instanteUtc, menuDoUsuario } from '../helpers';

// A casca do sistema, o menu do usuário, o perfil e o tema escuro.

test('a tela por inteiro e o menu do usuário', async ({ page, clinica }) => {
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, '09:00'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});

	await abrirAgenda(page, clinica);
	await foto(page, 'shell-01');

	await menuDoUsuario(page).click();
	await expect(page.getByRole('link', { name: 'Meu perfil' })).toBeVisible();
	await foto(page, 'shell-menu-01', { assentar: 300 });
});

test('perfil e sessão', async ({ page, clinica }) => {
	await page.goto('/perfil');
	await expect(page.getByRole('heading', { name: /perfil/i }).or(page.getByText(clinica.email))).toBeVisible();
	await foto(page, 'perfil-01', { assentar: 300 });

	const sessao = page.getByText('Sessão', { exact: true }).locator('xpath=ancestor::section[1]');
	if (await sessao.isVisible().catch(() => false)) await foto(sessao, 'perfil-sessao-01');
});

test('o tema escuro', async ({ page, clinica }) => {
	await abrirAgenda(page, clinica);
	// Pelo botão do rodapé do rail, e não por `emulateMedia`: é o caminho que o tópico manda usar,
	// e é ele que grava a preferência no cookie — fotografar o outro mostraria uma tela que a
	// pessoa não sabe como alcançar.
	await page.getByRole('button', { name: /tema|escuro|claro/i }).first().click();
	await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
	await foto(page, 'perfil-tema-01', { assentar: 400 });
});
