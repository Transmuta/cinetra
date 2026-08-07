import { test, expect, abrirAgenda, blocos } from './fixtures';
import { criarAgendamento, criarPaciente, instanteUtc, tipoPorNome } from './helpers';

/**
 * O drawer **não fecha** quando se age dentro dele.
 *
 * O bug (2026-08-06): o id do bloco aberto morava só em `page.state`, e `page.state` é **volátil**
 * — qualquer `invalidate`/`invalidateAll` o reescreve do zero. Como toda mutação do painel termina
 * em `invalidateAll` (o default do `use:enhance`) e o tempo real ainda recarrega sozinho 400ms
 * depois do evento da própria escrita, o painel sumia no meio do trabalho: marcar presença,
 * adicionar alguém à turma, cancelar.
 *
 * **Só o browser de verdade pega isto.** O `history.state` continua com o id e a barra de endereço
 * também — quem some é o espelho em memória do Kit, que não existe fora do roteador. E a espera
 * depois da ação não é cerimônia: era exatamente na janela dos 400ms do `recarregar` que o painel
 * fechava, então uma asserção imediata passa com o bug de pé (foi o que aconteceu na primeira
 * versão deste teste).
 */
const DEPOIS_DA_RECARGA = 900;

test.describe('O drawer sobrevive às ações', () => {
	test('cancelar pelo drawer mantém o painel aberto no mesmo bloco', async ({ page, clinica }) => {
		await criarAgendamento(clinica.api, {
			starts_at: instanteUtc(clinica.dia, '14:00'),
			professional_id: clinica.profissional.id,
			appointment_type_id: clinica.tipo.id,
			patient_ids: [clinica.paciente.id]
		});

		await abrirAgenda(page, clinica);
		await expect(blocos(page)).toHaveCount(1);
		await blocos(page).click();

		const drawer = page.getByRole('dialog', { name: 'Detalhes do agendamento' });
		await expect(drawer).toBeVisible();

		await drawer.getByRole('button', { name: 'Cancelar sessão' }).click();
		const confirmacao = page.getByRole('dialog', { name: 'Cancelar agendamento' });
		await expect(confirmacao).toBeVisible();
		await confirmacao.getByRole('button', { name: 'Cancelar agendamento' }).click();

		await page.waitForTimeout(DEPOIS_DA_RECARGA);

		// O bloco continua na agenda (cancelar não é excluir) — e o painel continua aberto nele,
		// mostrando o estado novo.
		await expect(blocos(page)).toHaveCount(1);
		await expect(drawer).toBeVisible();
		await expect(drawer.getByRole('button', { name: 'Reabrir agendamento' })).toBeVisible();
		await expect(page).toHaveURL(/agendamento=/);
	});

	// A composição da turma (doc 109) é onde isto mais dói: adicionar e tirar gente são duas ações
	// seguidas no MESMO painel, e com o bug a segunda não tinha painel para acontecer.
	test('compor a turma pelo drawer mantém o painel aberto', async ({ page, clinica }) => {
		const pilates = await tipoPorNome(clinica.api, 'Pilates');
		const segundo = await criarPaciente(clinica.api, 'Téo Barros');

		await criarAgendamento(clinica.api, {
			starts_at: instanteUtc(clinica.dia, '10:00'),
			professional_id: clinica.profissional.id,
			appointment_type_id: pilates.id,
			patient_ids: [clinica.paciente.id]
		});

		await abrirAgenda(page, clinica);
		await blocos(page).click();

		const drawer = page.getByRole('dialog', { name: 'Detalhes do agendamento' });
		await expect(drawer).toBeVisible();

		await drawer.getByRole('button', { name: 'Adicionar paciente' }).click();
		await drawer.getByRole('combobox').fill('Téo');
		await page.getByRole('option', { name: new RegExp(segundo.nome) }).click();
		await drawer.getByRole('button', { name: 'Adicionar', exact: true }).click();

		await expect(drawer.getByText(segundo.nome)).toBeVisible();
		await page.waitForTimeout(DEPOIS_DA_RECARGA);
		await expect(drawer).toBeVisible();

		// E a ação seguinte acontece no mesmo painel, sem reabrir nada.
		await drawer.getByRole('button', { name: `Tirar ${segundo.nome} da turma` }).click();
		const confirmacao = page.getByRole('dialog', { name: `Tirar ${segundo.nome} da turma` });
		await expect(confirmacao).toBeVisible();
		await confirmacao.getByRole('button', { name: 'Tirar da turma' }).click();

		await page.waitForTimeout(DEPOIS_DA_RECARGA);
		await expect(drawer).toBeVisible();
		await expect(drawer.getByText(segundo.nome)).toBeHidden();
		await expect(page).toHaveURL(/agendamento=/);
	});
});
