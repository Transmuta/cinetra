import { test, expect } from './autenticado';
import { foto } from './foto';
import { criarPaciente } from '../helpers';

// Pacientes e profissionais: as duas telas de cadastro, a ficha e a lista.

test('lista e cadastro de paciente', async ({ page, clinica }) => {
	await page.goto('/pacientes');
	await page.waitForLoadState('networkidle');
	await expect(page.getByRole('heading', { name: 'Pacientes' })).toBeVisible();
	await expect(page.getByText(clinica.paciente.nome).first()).toBeVisible();
	await foto(page, 'pacientes-lista-01');
	await foto(page, 'pacientes-busca-01');

	await page.goto('/pacientes/novo');
	await page.waitForLoadState('networkidle');
	await expect(page.getByRole('heading', { name: 'Identificação' })).toBeVisible();
	await foto(page, 'pacientes-novo-01', { assentar: 400 });

	// O consentimento é a última seção do formulário — e a que decide se o paciente pode receber
	// mensagem. Rolar até ela é o que a pessoa faz de verdade; o formulário é uma página só.
	const consentimento = page.getByRole('heading', { name: 'Consentimento' });
	await consentimento.scrollIntoViewIfNeeded();
	await foto(page, 'pacientes-novo-02', { assentar: 400 });
});

test('o aviso de ficha repetida', async ({ page, clinica }) => {
	// A ficha existente é criada AQUI, com telefone conhecido: o da fixture é aleatório
	// (`telUnico`, por causa da identidade `tel_unico` do doc 89), então digitá-lo era impossível —
	// e a captura vinha silenciosamente vazia, porque o passo estava dentro de um `if (visível)`.
	const tel = '11987654321';
	await clinica.api.post('/api/patients', { data: { nome: 'Marina Prado', tel } });

	await page.goto('/pacientes/novo');
	await page.waitForLoadState('networkidle');
	await page.getByPlaceholder('(11) 90000-0000').first().fill(tel);
	await page.getByPlaceholder('Nome do paciente').fill('Marina Prado');

	// A consulta é adiada (400ms) enquanto se digita; sem esperar o AVISO em si, a foto sai antes.
	const aviso = page.getByText(/já cadastrado/).first();
	await expect(aviso).toBeVisible();
	await foto(aviso.locator('xpath=ancestor::*[3]'), 'pacientes-duplicado-01');
});

test('a ficha do paciente', async ({ page, clinica }) => {
	await page.goto(`/pacientes/${clinica.paciente.id}`);
	await page.waitForLoadState('networkidle');
	await expect(page.getByText(clinica.paciente.nome).first()).toBeVisible();
	await foto(page, 'pacientes-ficha-01', { assentar: 400 });
	await foto(page, 'pacientes-arquivar-01');

	const anexos = page.locator('section').filter({ hasText: 'Anexos e documentos' }).last();
	if (await anexos.isVisible().catch(() => false)) await foto(anexos, 'pacientes-anexos-01');
});

test('paciente arquivado', async ({ page, clinica }) => {
	const p = await criarPaciente(clinica.api, 'Helena Costa');
	await page.goto(`/pacientes/${p.id}`);
	await page.getByRole('button', { name: /Arquivar/ }).click();
	const confirmar = page.getByRole('dialog');
	if (await confirmar.isVisible().catch(() => false)) {
		await confirmar.getByRole('button', { name: /Arquivar|Confirmar/ }).last().click();
	}
	await expect(page.getByText('Paciente arquivado')).toBeVisible();
	await foto(page, 'pacientes-arquivado-01', { assentar: 400 });
});

test('profissionais', async ({ page, clinica }) => {
	await page.goto('/profissionais');
	await page.waitForLoadState('networkidle');
	await expect(page.getByRole('heading', { name: 'Profissionais' })).toBeVisible();
	await foto(page, 'profissionais-lista-01');

	await page.goto('/profissionais/novo');
	await page.waitForLoadState('networkidle');
	await expect(page.getByRole('heading', { name: 'Identificação pessoal' })).toBeVisible();
	await foto(page, 'profissionais-novo-01', { assentar: 400 });
});

test('horário, cor e status do profissional', async ({ page, clinica }) => {
	await page.goto(`/profissionais/${clinica.profissional.id}`);
	await page.waitForLoadState('networkidle');
	await expect(page.getByRole('heading', { name: 'Horário de atendimento' })).toBeVisible();

	const horario = page.getByText('Seguir o horário da clínica').locator('xpath=ancestor::*[3]');
	await expect(horario).toBeVisible();
	await foto(horario, 'profissionais-horario-01');

	const cor = page.getByText('Cor do avatar na agenda').locator('xpath=ancestor::*[2]');
	if (await cor.isVisible().catch(() => false)) await foto(cor, 'profissionais-cor-01');

	const status = page.getByText('Profissional ativo').locator('xpath=ancestor::*[2]');
	if (await status.isVisible().catch(() => false)) await foto(status, 'profissionais-inativar-01');
});
