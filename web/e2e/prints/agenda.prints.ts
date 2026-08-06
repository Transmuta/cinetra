import { test, expect, abrirAgenda, blocos } from './autenticado';
import { foto } from './foto';
import { criarAgendamento, instanteUtc, criarPaciente, tipoPorNome } from '../helpers';

// A agenda — a seção mais fotografada da central, porque é a mais usada e a que mais gera dúvida.
//
// Cada teste semeia o que precisa e fotografa; nenhum depende do estado deixado por outro. É o
// mesmo princípio da suíte e2e (uma clínica por teste) e vale aqui por um motivo a mais: print
// tirada de um estado herdado mostra dado que o texto não explica.

const HORA = '09:00';

/** O último dia útil ANTES de hoje — onde um atendimento já começou e ainda cabe no expediente. */
function diaUtilAnterior(): string {
	const d = new Date();
	do {
		d.setDate(d.getDate() - 1);
	} while (d.getDay() === 0 || d.getDay() === 6);
	return d.toISOString().slice(0, 10);
}

test('as quatro visões', async ({ page, clinica }) => {
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, HORA),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, '10:30'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});

	await abrirAgenda(page, clinica);
	await expect(blocos(page)).toHaveCount(2);
	await foto(page, 'agenda-dia-01');
	await foto(page, 'agenda-marcar-03');

	// A lateral com os profissionais e o controle de ocultar.
	await foto(page.getByRole('complementary').first(), 'agenda-filtro-01');
	await foto(page.locator('[data-legenda]').first().or(page.getByRole('main')), 'agenda-legenda-01');

	for (const [visao, id] of [
		['Semana', 'agenda-semana-01'],
		['Mês', 'agenda-mes-01'],
		['Lista', 'agenda-lista-01']
	] as const) {
		await page.getByRole('button', { name: visao, exact: true }).click();
		await expect(page.getByRole('button', { name: visao, exact: true })).toHaveAttribute(
			'aria-current',
			'page'
		);
		await foto(page, id, { assentar: 400 });
	}
});

test('marcar um atendimento', async ({ page, clinica }) => {
	await abrirAgenda(page, clinica);

	// A grade vazia, com o cursor sobre o horário livre — o passo 1 do tópico.
	await foto(page, 'agenda-marcar-01');

	await page.getByRole('button', { name: 'Novo agendamento' }).click();
	const modal = page.getByRole('dialog');
	await expect(modal).toBeVisible();
	await modal.getByRole('combobox').first().waitFor();
	await foto(modal, 'agenda-marcar-02', { assentar: 300 });
});

test('conflito e encaixe', async ({ page, clinica }) => {
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, HORA),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});
	const outro = await criarPaciente(clinica.api, 'Joana Ribeiro');

	await abrirAgenda(page, clinica);
	await page.getByRole('button', { name: 'Novo agendamento' }).click();
	const modal = page.getByRole('dialog');
	await expect(modal).toBeVisible();

	// A chave de encaixe, no formulário — antes de qualquer erro.
	await foto(modal.getByText('Encaixe', { exact: true }).locator('xpath=..'), 'agenda-encaixe-01');

	// Agora o 422 de conflito, com a saída dentro da caixa de erro.
	await modal.getByRole('combobox', { name: 'Buscar paciente' }).fill('Joana');
	await modal.getByRole('option', { name: /Joana Ribeiro/ }).first().click();
	await modal.getByLabel('Hora').fill(HORA);
	await modal.getByRole('button', { name: 'Agendar' }).click();
	await expect(modal.getByRole('button', { name: 'Marcar como encaixe' })).toBeVisible();
	await foto(modal, 'agenda-conflito-01');
	void outro;
});

test('o painel do agendamento', async ({ page, clinica }) => {
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, HORA),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id],
		obs: 'Trazer o exame de imagem.'
	});

	await abrirAgenda(page, clinica);
	await blocos(page).first().click();

	const painel = page.getByRole('dialog', { name: 'Detalhes do agendamento' });
	await expect(painel).toBeVisible();
	await foto(painel, 'agenda-painel-01', { assentar: 300 });
	await foto(painel, 'agenda-presenca-01');
	await foto(painel, 'agenda-link-01');

	// Remarcar.
	await painel.getByRole('button', { name: /Remarcar sessão/ }).click();
	const remarcar = page.getByRole('dialog', { name: 'Remarcar sessão' });
	await expect(remarcar).toBeVisible();
	await foto(remarcar, 'agenda-remarcar-01', { assentar: 300 });
	await remarcar.getByRole('button', { name: 'Cancelar' }).click();

	// Cancelar (a confirmação com o motivo). O botão do painel é "Cancelar sessão" — o "Cancelar"
	// seco é o de fechar modal, e casar por ele fecharia a tela em vez de abrir o diálogo.
	await painel.getByRole('button', { name: 'Cancelar sessão' }).click();
	const confirmar = page.getByRole('dialog', { name: 'Cancelar agendamento' });
	await expect(confirmar).toBeVisible();
	await foto(confirmar, 'agenda-cancelar-01', { assentar: 300 });
	await page.keyboard.press('Escape');

	// Excluir (a confirmação que explica a diferença).
	await painel.getByRole('button', { name: 'Excluir agendamento' }).click();
	const excluir = page.getByRole('dialog', { name: 'Excluir agendamento' });
	await expect(excluir).toBeVisible();
	await foto(excluir, 'agenda-excluir-01', { assentar: 300 });
});

test('encaixe marcado e falta', async ({ page, clinica }) => {
	// Um encaixe já criado: o painel mostra a marca ENCAIXE.
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, HORA),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, HORA),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [(await criarPaciente(clinica.api, 'Carlos Souza')).id],
		encaixe: true
	});

	await abrirAgenda(page, clinica);
	await page.locator('[data-appt]').last().click();
	const painel = page.getByRole('dialog', { name: 'Detalhes do agendamento' });
	await expect(painel.getByText('ENCAIXE')).toBeVisible();
	await foto(painel, 'agenda-encaixe-02', { assentar: 300 });
});

test('turma', async ({ page, clinica }) => {
	const turma = await tipoPorNome(clinica.api, 'Pilates');
	const [a, b] = await Promise.all([
		criarPaciente(clinica.api, 'Ana Lima'),
		criarPaciente(clinica.api, 'Bruno Reis')
	]);

	await abrirAgenda(page, clinica);
	await page.getByRole('button', { name: 'Novo agendamento' }).click();
	const modal = page.getByRole('dialog');
	// Pelo id, não pelo rótulo: a opção escreve nome, duração e "· grupo" juntos, e casar isso
	// por texto quebra no dia em que a duração do tipo mudar.
	await modal.getByLabel('Tipo').selectOption(turma.id);
	const buscar = modal.getByRole('combobox', { name: 'Buscar paciente' });
	await buscar.fill('Ana');
	await modal.getByRole('option', { name: /Ana Lima/ }).first().click();
	await buscar.fill('Bruno');
	await modal.getByRole('option', { name: /Bruno Reis/ }).first().click();
	await foto(modal, 'agenda-turma-01', { assentar: 300 });

	await modal.getByRole('button', { name: 'Agendar' }).click();
	await expect(blocos(page)).toHaveCount(1);
	await blocos(page).first().click();
	const painel = page.getByRole('dialog', { name: 'Detalhes do agendamento' });
	await expect(painel.getByText('Pacientes na turma')).toBeVisible();
	await foto(painel, 'agenda-turma-02', { assentar: 300 });
	void [a, b];
});

test('registrar falta', async ({ page, clinica }) => {
	// Presença e falta só ficam clicáveis DEPOIS do horário da sessão (RN-58), então esta print
	// precisa de um bloco que já começou.
	//
	// E ele tem de estar DENTRO do expediente: o encaixe suprime conflito, não indisponibilidade
	// (D14) — a primeira versão disto marcava "uma hora atrás" e levava 422 de
	// `outside_business_hours` de madrugada. Daí o último dia útil às 09:00.
	const dia = diaUtilAnterior();
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(dia, '09:00'),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});

	// Mesmo cuidado do `abrirAgenda`: o grid vem no HTML do SSR, então ele fica visível antes de
	// ter handler — e o clique some sem erro nenhum.
	const hidratou = page.waitForResponse((r) => r.url().includes('/api/realtime/token'));
	await page.goto(`/agenda?date=${dia}`);
	await expect(blocos(page)).toHaveCount(1);
	await hidratou;
	await blocos(page).first().click();

	const painel = page.getByRole('dialog', { name: 'Detalhes do agendamento' });
	await expect(painel).toBeVisible();
	await painel.getByRole('button', { name: 'Faltou' }).first().click();

	const dialogo = page.getByRole('dialog', { name: /Registrar falta/ });
	await expect(dialogo).toBeVisible();
	await foto(dialogo, 'agenda-falta-01', { assentar: 300 });
});

test('quem mais está com o dia aberto', async ({ page, context, browser, clinica }) => {
	await criarAgendamento(clinica.api, {
		starts_at: instanteUtc(clinica.dia, HORA),
		professional_id: clinica.profissional.id,
		appointment_type_id: clinica.tipo.id,
		patient_ids: [clinica.paciente.id]
	});
	await abrirAgenda(page, clinica);

	// A segunda sessão é de VERDADE — outro contexto, mesma sessão do dono, mesmo dia. Não há
	// como forjar isso: o indicador vem da presença no canal do dia.
	const outro = await browser.newContext({ storageState: await context.storageState() });
	const outraPagina = await outro.newPage();
	await outraPagina.goto(`/agenda?date=${clinica.dia}`);

	const barra = page.getByRole('main').locator('xpath=//*[contains(@class,"border-b")][1]');
	await page.waitForTimeout(2_000);
	await foto(barra.first(), 'agenda-presenca-tempo-real-01');
	await outro.close();
});
