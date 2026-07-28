import { test, expect, abrirAgenda, blocos, montarClinica } from './fixtures';
import { criarAgendamento, instanteUtc } from './helpers';

/**
 * Isolamento entre clínicas — o teste de segurança que vale por dez.
 *
 * O sistema é multi-tenant por atributo (`clinic_id`, ADR-017) com RLS no banco, e o modo de falha
 * dessa arquitetura é sempre o mesmo: uma leitura que esquece o escopo. O que torna essa classe
 * traiçoeira é que ela é **invisível ao `mix test`** — o sandbox conecta como `postgres`, que é
 * SUPERUSER e bypassa RLS, então a leitura sem escopo passa verde ali e vaza (ou volta vazia) no
 * servidor de verdade, que conecta como `movimento_app`. Já mordeu três vezes.
 *
 * O job `api-rls` do CI fecha parte do buraco, mas só para os testes marcados `@tag :rls`. Aqui a
 * prova é pelo **caminho inteiro**: browser → BFF → API → policy → RLS, com um usuário que não tem
 * vínculo nenhum com a outra clínica. Ele não descobre o id em lugar nenhum da interface — o teste
 * o entrega de bandeja, que é exatamente o que um atacante faria.
 */
test.describe('Isolamento entre clínicas', () => {
	test('o vizinho não abre paciente, profissional nem agenda de outra clínica', async ({
		page,
		browser,
		request,
		clinica
	}) => {
		// A clínica da fixture ganha um bloco no dia: é o que a agenda da vizinha NÃO pode mostrar.
		await criarAgendamento(clinica.api, {
			starts_at: instanteUtc(clinica.dia, '11:00'),
			professional_id: clinica.profissional.id,
			appointment_type_id: clinica.tipo.id,
			patient_ids: [clinica.paciente.id]
		});
		await abrirAgenda(page, clinica);
		await expect(blocos(page)).toHaveCount(1);

		// Outra pessoa, outra sessão, outra clínica — sem nenhum vínculo com a primeira.
		const contextoVizinho = await browser.newContext();
		const paginaVizinho = await contextoVizinho.newPage();
		const vizinha = await montarClinica(paginaVizinho, contextoVizinho, request, 'vizinha');

		// 1) A ficha, pela URL. 404 e não 403 de propósito: a existência do registro também é
		//    informação — "esse id existe, mas não é seu" já diz demais.
		await paginaVizinho.goto(`/pacientes/${clinica.paciente.id}`);
		await expect(paginaVizinho.getByText('404')).toBeVisible();

		// 2) A ficha do profissional, idem.
		await paginaVizinho.goto(`/profissionais/${clinica.profissional.id}`);
		await expect(paginaVizinho.getByText('404')).toBeVisible();

		// 3) A agenda do MESMO dia: a coluna é a da vizinha, e o bloco da outra clínica não está lá.
		await abrirAgenda(paginaVizinho, vizinha);
		await expect(blocos(paginaVizinho)).toHaveCount(0);

		// 4) E direto na API, sem a interface no meio — é lá que a policy e a RLS decidem.
		expect((await vizinha.api.get(`/api/patients/${clinica.paciente.id}`)).status()).toBe(404);
		expect(
			(await vizinha.api.get(`/api/professionals/${clinica.profissional.id}`)).status()
		).toBe(404);

		const agenda = await vizinha.api.get(
			`/api/appointments?from=${clinica.dia}&to=${clinica.dia}`
		);
		const { appointments } = (await agenda.json()) as { appointments: unknown[] };
		expect(appointments).toHaveLength(0);

		await vizinha.api.dispose();
		await contextoVizinho.close();
	});
});
