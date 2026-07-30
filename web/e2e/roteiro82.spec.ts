import type { Locator, Page } from '@playwright/test';
import { test, expect, abrirAgenda, blocos } from './fixtures';
import { criarAgendamento, criarPaciente, telUnico, tipoPorNome } from './helpers';

/**
 * O roteiro de QA guiado (doc 82), na parte que **só a tela prova**.
 *
 * As regras de negócio do roteiro — validações do cadastro, conflito, encaixe, expediente, 409,
 * upsert da fila, a matriz de acesso inteira — foram exercidas contra a API na mesma rodada, e é
 * lá que elas são baratas e definitivas. O que sobra para cá é o que a API não responde: se o
 * **card** conta a verdade sobre a turma, se o **rodapé** explica a recusa, se a fórmula abre por
 * clique (e não só por hover), se o Esc fecha a gaveta. Cada teste cita o item do roteiro.
 */

/** Um dia útil no PASSADO — presença só é aceita depois da hora (D-E4.1). */
function diaUtilPassado(atras = 3): string {
	const d = new Date();
	d.setUTCDate(d.getUTCDate() - atras);
	// Sáb (6) → sexta; Dom (0) → sexta.
	if (d.getUTCDay() === 6) d.setUTCDate(d.getUTCDate() - 1);
	if (d.getUTCDay() === 0) d.setUTCDate(d.getUTCDate() - 2);
	return d.toISOString().slice(0, 10);
}

/** A gaveta de detalhe do agendamento. */
function drawer(page: Page) {
	return page.getByRole('dialog');
}

/**
 * Espera o cliente assumir a página antes do primeiro clique.
 *
 * A grade e os formulários vêm prontos do SSR, então `toBeVisible` passa na hora — e o clique
 * ainda atinge um DOM **sem handler**, sumindo sem erro nenhum. É a mesma armadilha que o
 * `abrirAgenda` desarma com o pedido do token; aqui, onde não há esse sinal, `networkidle` é o
 * mais barato que serve. Sem isto, o aviso de duplicado e a fórmula do KPI falhavam por corrida —
 * e as duas telas funcionam quando conferidas à mão.
 */
async function hidratou(page: Page) {
	await page.waitForLoadState('networkidle');
}

/**
 * Digita o CPF e **confere que ele entrou inteiro** antes de seguir.
 *
 * A primeira tecla se perde se a página ainda não hidratou: ela cai num input cujo `oninput` não
 * existe, o estado do Svelte não muda, e a hidratação reescreve `value={f.cpf}` — ainda vazio —
 * por cima. Medido: `39053344705` virava `905.334.470-5`, dez dígitos. Com o CPF incompleto o
 * lookup de duplicado nem dispara (ele exige 11), e o teste falhava acusando o aviso ausente em
 * vez da tecla comida.
 *
 * O `toPass` redigita até o campo realmente conter o que se quis digitar — que é a única
 * afirmação que interessa aqui.
 */
async function digitarCpf(campo: Locator, cpf: string) {
	await expect(async () => {
		await campo.fill('');
		await campo.pressSequentially(cpf, { delay: 20 });
		await expect(campo).toHaveValue(new RegExp(`\\d{3}\\.\\d{3}\\.\\d{3}-\\d{2}$`), {
			timeout: 1_000
		});
	}).toPass({ timeout: 20_000 });
}

test.describe('Roteiro 82 · §6 agenda', () => {
	test('turma com 1 presente e 1 falta vira "1 de 2 concluídas", não "Concluído" (D13)', async ({
		page,
		clinica
	}) => {
		const dia = diaUtilPassado();
		const [pilates, segundo] = await Promise.all([
			tipoPorNome(clinica.api, 'Pilates'),
			criarPaciente(clinica.api, 'João Ribeiro')
		]);

		const turma = await criarAgendamento(clinica.api, {
			starts_at: `${dia}T09:00:00-03:00`,
			professional_id: clinica.profissional.id,
			appointment_type_id: pilates.id,
			patient_ids: [clinica.paciente.id, segundo.id]
		});

		// Uma presença de cada tipo — é a combinação que o D13 nomeia.
		const marcar = (pid: string, acao: string) =>
			clinica.api.post(`/api/appointments/${turma.id}/participants/${pid}/${acao}`, { data: {} });
		expect((await marcar(clinica.paciente.id, 'complete')).ok()).toBe(true);
		expect((await marcar(segundo.id, 'no_show')).ok()).toBe(true);

		await page.goto(`/agenda?date=${dia}`);
		const bloco = blocos(page).first();
		await expect(bloco).toBeVisible();

		// O rollup manda no que se lê: a composição, não a palavra.
		await expect(bloco).toContainText('1 de 2 concluídas');
		await expect(bloco).not.toContainText('Concluído');
	});

	test('Presente/Faltou ficam desabilitados antes do horário (D-E4.1)', async ({
		page,
		clinica
	}) => {
		// O bloco da fixture é uma semana à frente — ninguém compareceu ainda.
		const futuro = await criarAgendamento(clinica.api, {
			starts_at: `${clinica.dia}T09:00:00-03:00`,
			professional_id: clinica.profissional.id,
			appointment_type_id: clinica.tipo.id,
			patient_ids: [clinica.paciente.id]
		});
		expect(futuro.id).toBeTruthy();

		await abrirAgenda(page, clinica);
		await blocos(page).first().click();
		await expect(drawer(page)).toBeVisible();

		await expect(drawer(page).getByRole('button', { name: /Presente/ })).toBeDisabled();
		await expect(drawer(page).getByRole('button', { name: /Faltou/ })).toBeDisabled();
	});

	test('Esc fecha a gaveta e devolve o foco (§14)', async ({ page, clinica }) => {
		await criarAgendamento(clinica.api, {
			starts_at: `${clinica.dia}T09:00:00-03:00`,
			professional_id: clinica.profissional.id,
			appointment_type_id: clinica.tipo.id,
			patient_ids: [clinica.paciente.id]
		});

		await abrirAgenda(page, clinica);
		await blocos(page).first().click();
		await expect(drawer(page)).toBeVisible();

		await page.keyboard.press('Escape');
		await expect(drawer(page)).toHaveCount(0);
	});
});

test.describe('Roteiro 82 · §4 cadastro de paciente', () => {
	/**
	 * O aviso de duplicado, que desde o doc 89 deixou de ser conveniência.
	 *
	 * Enquanto duplicado só avisava, este aviso era gentileza. Agora que o servidor **recusa** CPF,
	 * telefone e e-mail repetidos, ele é o que evita digitar a ficha inteira para levar um 422 no
	 * fim — e por isso precisa NOMEAR a outra ficha, senão a recepção não sabe o que fazer.
	 *
	 * Este teste já foi retirado uma vez, por instabilidade (`detached from the DOM, retrying`).
	 * A causa não era o formulário: era um `build/` velho sendo servido pelo preview reusado — o
	 * mesmo A-14 que mantinha o `agendar.spec.ts` verde e quebrado. Medido depois, com build fresco,
	 * o nó do CPF nunca é substituído (`isConnected` segue true por 11 dígitos, debounce e lookup).
	 */
	test('CPF já usado avisa nomeando a outra ficha, antes de tentar salvar', async ({
		page,
		clinica
	}) => {
		const cpf = '39053344705';
		const res = await clinica.api.post('/api/patients', {
			data: { nome: 'Marina Original', tel: telUnico(), cpf }
		});
		expect(res.ok()).toBe(true);

		await page.goto('/pacientes/novo');
		const campoCpf = page.getByRole('textbox', { name: 'CPF' });
		await expect(campoCpf).toBeVisible();

		await page.getByRole('textbox', { name: /Nome completo/ }).fill('Clone Da Marina');
		await digitarCpf(campoCpf, cpf);

		// O aviso nomeia a outra ficha e diz o que fazer — é o que evita preencher 31 campos
		// para levar o 422 no fim.
		await expect(page.getByText(/já cadastrado/)).toBeVisible({ timeout: 10_000 });
		await expect(page.getByText(/Marina Original/)).toBeVisible();
	});

	test('CPF com dígito errado barra o salvar e explica no rodapé (D10)', async ({
		page,
		clinica
	}) => {
		expect(clinica.id).toBeTruthy();
		await page.goto('/pacientes/novo');
		const campoCpf = page.getByRole('textbox', { name: 'CPF' });
		await expect(campoCpf).toBeVisible();

		await page.getByRole('textbox', { name: /Nome completo/ }).fill('Cpf Invalido');
		// Nome exato: há um segundo "Telefone" na seção de Emergência.
		await page.getByRole('textbox', { name: 'Telefone / WhatsApp*' }).fill('11991234567');
		await digitarCpf(campoCpf, '12345678900');

		// Nome e telefone preenchidos: o que segura o salvar é só o CPF.
		await expect(page.getByRole('button', { name: /Cadastrar paciente/ })).toBeDisabled();
		await expect(page.getByText(/CPF inválido/)).toBeVisible();
	});
});

test.describe('Roteiro 82 · §11 relatórios', () => {
	test('a fórmula do KPI abre por CLIQUE, não só por hover (AN-05 / ACC-10)', async ({
		page,
		clinica
	}) => {
		expect(clinica.id).toBeTruthy();
		await page.goto('/relatorios');
		await hidratou(page);

		const ajuda = page.getByRole('button', { name: /Como .* é calculado/ }).first();
		await expect(ajuda).toBeVisible();
		await ajuda.click();

		await expect(page.getByText(/Como calculamos:/)).toBeVisible();
	});
});

test.describe('Roteiro 82 · §15 públicas', () => {
	// Autenticado de propósito: deslogado, uma rota desconhecida do shell cai na guarda de sessão
	// e vira redirect para `/entrar` (200) — o 404 nunca chega a ser exercido.
	test('rota inexistente devolve a página de erro do app, não stack trace', async ({
		page,
		clinica
	}) => {
		expect(clinica.id).toBeTruthy();
		const resposta = await page.goto('/rota-que-nao-existe-qa82');
		expect(resposta?.status()).toBe(404);

		// `exact` porque o nome gerado da clínica de teste pode conter "404" por acaso — e conteve.
		await expect(page.getByText('404', { exact: true })).toBeVisible();
		// O sintoma que reprova: entranhas do framework na tela.
		await expect(page.locator('body')).not.toContainText('at Object.');
		await expect(page.locator('body')).not.toContainText('node_modules');
	});
});
