import { test, expect } from './autenticado';
import { foto } from './foto';

// Configurações e equipe.
//
// Os seletores saem do DOM real (levantado com um andaime que imprimia títulos e botões de cada
// tela), não do que o componente PARECE expor: o título "Horário de atendimento da clínica", por
// exemplo, não existe como cabeçalho na página — a tela abre direto na grade dos dias.

test('dados da clínica', async ({ page }) => {
	await page.goto('/configuracoes/clinica');
	await page.waitForLoadState('networkidle');
	await expect(page.getByLabel('CNPJ')).toBeVisible();
	await foto(page, 'config-clinica-01', { assentar: 300 });
});

test('tipos de atendimento', async ({ page }) => {
	await page.goto('/configuracoes/tipos');
	await page.waitForLoadState('networkidle');
	await expect(page.getByRole('heading', { name: 'Tipos de atendimento' })).toBeVisible();
	await foto(page, 'config-tipos-01', { assentar: 300 });

	await page.getByRole('button', { name: 'Novo tipo' }).click();
	const modal = page.getByRole('dialog');
	await expect(modal).toBeVisible();
	await modal.getByLabel('Nome').fill('Sessão em dupla');
	await foto(modal, 'config-tipos-02', { assentar: 300 });

	await modal.getByRole('switch', { name: 'Atendimento em grupo' }).click();
	await expect(modal.getByLabel('Capacidade do grupo')).toBeVisible();
	await foto(modal, 'config-tipos-grupo-01', { assentar: 200 });
});

test('horário', async ({ page }) => {
	await page.goto('/configuracoes/horario');
	await page.waitForLoadState('networkidle');
	await expect(page.getByRole('button', { name: /Espelhar Seg/ })).toBeVisible();
	await foto(page, 'config-horario-01', { assentar: 400 });
});

test('exceções', async ({ page }) => {
	await page.goto('/configuracoes/excecoes');
	await page.waitForLoadState('networkidle');
	await expect(page.getByRole('heading', { name: 'Exceções da agenda' })).toBeVisible();
	await foto(page, 'config-excecoes-01', { assentar: 300 });
});

test('equipe e acessos', async ({ page }) => {
	await page.goto('/configuracoes/equipe');
	await page.waitForLoadState('networkidle');
	await expect(page.getByRole('heading', { name: 'Membros da organização' })).toBeVisible();
	await foto(page, 'equipe-lista-01', { assentar: 400 });

	const matriz = page.locator('section').filter({ hasText: 'O que cada papel pode' }).last();
	await expect(matriz).toBeVisible();
	await foto(matriz, 'equipe-matriz-01');

	const membros = page.locator('section').filter({ hasText: 'Membros da organização' }).last();
	await foto(membros, 'equipe-acoes-01');

	await page.getByRole('button', { name: 'Convidar membro' }).click();
	const modal = page.getByRole('dialog');
	await expect(modal).toBeVisible();
	await foto(modal, 'equipe-convite-01', { assentar: 300 });
});

test('comunicação', async ({ page }) => {
	await page.goto('/configuracoes/comunicacao');
	await page.waitForLoadState('networkidle');
	// Pelo interruptor, não pelo texto ao lado dele: o mesmo rótulo aparece duas vezes na tela
	// (no controle e no resumo em modo leitura), e o `getByText` cru dependia de qual delas o
	// papel de quem fotografa faz renderizar.
	await expect(page.getByRole('switch', { name: 'Falar por WhatsApp' })).toBeVisible();
	await foto(page, 'comunicacao-01', { assentar: 300 });
});
