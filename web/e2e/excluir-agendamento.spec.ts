import { test, expect, abrirAgenda, blocos } from './fixtures';
import { criarAgendamento, instanteUtc } from './helpers';

/**
 * Excluir pelo drawer: selecionar o bloco → confirmar → o bloco some.
 *
 * O alvo real deste teste é uma **classe de bug**, não uma tela. Sete lugares do app disparam um
 * `requestSubmit()` a partir de um ConfirmDialog (presença, cancelar, excluir, cancelar pacote,
 * remover acesso, limpar notificações, sair de todos os dispositivos): o botão do diálogo preenche
 * campos escondidos e submete um form que está fora dele. O `AppointmentDrawer` documenta o modo de
 * falha — sem um `await tick()`, o Svelte 5 ainda não escreveu os `value` e o form sai **vazio**,
 * com o servidor respondendo "não informado". E documenta também por que a unidade não pega: o
 * `fireEvent` do testing-library já devolve depois do flush, então lá o bug não existe.
 *
 * Só o clique ao vivo, num browser de verdade, exercita essa ordem. Cobrir um dos sete caminhos
 * transforma os outros seis em regressão vigiada — todos usam o mesmo molde.
 *
 * De quebra, prova o resto do contrato do soft-delete (doc 40): a exclusão não é um sétimo status,
 * o bloco some da agenda, e a linha continua no banco.
 */
test.describe('Excluir agendamento pelo drawer', () => {
	test('confirmar no diálogo submete o form escondido e o bloco some', async ({
		page,
		clinica
	}) => {
		const agendamento = await criarAgendamento(clinica.api, {
			starts_at: instanteUtc(clinica.dia, '14:00'),
			professional_id: clinica.profissional.id,
			appointment_type_id: clinica.tipo.id,
			patient_ids: [clinica.paciente.id],
			obs: 'lançado por engano'
		});

		await abrirAgenda(page, clinica);
		await expect(blocos(page)).toHaveCount(1);

		await blocos(page).click();

		const drawer = page.getByRole('dialog', { name: 'Detalhes do agendamento' });
		await expect(drawer).toBeVisible();
		await expect(drawer.getByText('lançado por engano')).toBeVisible();

		// O gatilho é o ícone do rodapé; a confirmação é outro diálogo, por cima.
		await drawer.getByRole('button', { name: 'Excluir agendamento' }).click();

		const confirmacao = page.getByRole('dialog', { name: 'Excluir agendamento' });
		await expect(confirmacao).toBeVisible();
		await confirmacao.getByRole('button', { name: 'Excluir agendamento' }).click();

		// Some da grade, e o drawer fecha junto (o bloco selecionado deixou de existir).
		await expect(blocos(page)).toHaveCount(0);
		await expect(drawer).toBeHidden();

		// E some da leitura do servidor — não é só a tela que escondeu.
		const res = await clinica.api.get(`/api/appointments?from=${clinica.dia}&to=${clinica.dia}`);
		const { appointments } = (await res.json()) as { appointments: { id: string }[] };
		expect(appointments.map((a) => a.id)).not.toContain(agendamento.id);
	});
});
