import { test, expect } from './autenticado';
import { foto } from './foto';
import { criarAgendamento, instanteUtc } from '../helpers';

// Relatórios, auditoria, notificações e a comunicação dentro do painel — as telas de consulta.

test('relatórios', async ({ page, clinica }) => {
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, '09:00'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});

	await page.goto('/relatorios');
	await expect(page.getByText('Atendimentos').first()).toBeVisible();
	await foto(page, 'relatorios-01', { assentar: 600 });

	const volume = page.getByText(/Volume por/).locator('xpath=ancestor::div[2]');
	if (await volume.isVisible().catch(() => false)) {
		await foto(volume, 'relatorios-volume-01', { assentar: 300 });
	}
});

test('auditoria', async ({ page, clinica }) => {
	// A trilha precisa ter o que mostrar: o cadastro do cenário já gerou eventos, e um
	// agendamento a mais garante uma linha de agenda na lista.
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, '11:00'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});

	await page.goto('/auditoria');
	await expect(page.getByRole('main')).toBeVisible();
	await foto(page, 'auditoria-01', { assentar: 800 });

	// O detalhe de UMA entrada. Não há clique: `AuditEntry` já desenha o antes/depois na própria
	// linha — a versão anterior desta captura procurava um botão de expandir que nunca existiu, e
	// por estar dentro de um `if (visível)` falhava calada.
	const entrada = page.getByRole('main').locator('article, li, [data-entry]').first();
	const alvo = (await entrada.count()) ? entrada : page.getByRole('main');
	await foto(alvo, 'auditoria-detalhe-01', { assentar: 400 });
});

test('notificações', async ({ page, clinica }) => {
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, '14:00'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});

	await page.goto('/notificacoes');
	// `.first()`: o título da seção e o da caixa repetem a palavra, e o modo estrito recusa duas.
	await expect(page.getByRole('heading', { name: 'Notificações' }).first()).toBeVisible();
	await foto(page, 'notificacoes-01', { assentar: 600 });
});

test('a comunicação do atendimento', async ({ page, clinica }) => {
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, '09:00'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});

	const hidratou = page.waitForResponse((r) => r.url().includes('/api/realtime/token'));
	await page.goto(`/agenda?date=${clinica.dia}`);
	await expect(page.locator('[data-appt]')).toHaveCount(1);
	await hidratou;
	await page.locator('[data-appt]').first().click();

	const painel = page.getByRole('dialog', { name: 'Detalhes do agendamento' });
	await expect(painel).toBeVisible();
	const timeline = painel.getByText('Comunicação').locator('xpath=ancestor::*[1]');
	await expect(timeline).toBeVisible();
	await foto(timeline, 'comunicacao-timeline-01', { assentar: 600 });
});
