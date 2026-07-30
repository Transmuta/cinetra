import { test, expect, abrirAgenda, blocos, joinDaAgenda } from './fixtures';
import { criarAgendamento, instanteUtc } from './helpers';

/**
 * Tempo real (Entrega 3 / ADR-004): o que o servidor empurra chega em **toda** aba aberta naquele
 * dia, sem ninguém recarregar.
 *
 * É o cenário com a maior distância entre o que a suíte de unidade cobre e o que roda em produção.
 * O `realtime.test.ts` faz `vi.mock('phoenix')` — ou seja, o `Socket` inteiro é um dublê, e nada
 * ali toca no que de fato quebra:
 *
 *  * o **token no subprotocolo** (`Sec-WebSocket-Protocol`), que na Onda 5 já passou verde na suíte
 *    inteira enquanto devolvia 403 no fio;
 *  * o `check_origin` do endpoint;
 *  * e sobretudo a **CSP**, que é assada no BUILD (`connect-src`) e é lida em RUNTIME pelo BFF.
 *    Divergir não dá erro de servidor: dá agenda que para de atualizar sozinha, com o motivo só no
 *    console de quem está usando. Este teste roda contra o `build` + `preview` — é o único lugar da
 *    pirâmide onde a CSP de verdade está no ar.
 *
 * Duas abas, e não uma, porque o valor está no fan-out: quem tem a agenda aberta na recepção e quem
 * a tem aberta na sala têm de ver a mesma coisa.
 */
test.describe('Tempo real na agenda', () => {
	test('o bloco aparece e some nas duas abas, sem recarregar', async ({ page, context, clinica }) => {
		const abaB = await context.newPage();

		// Os listeners de socket precisam existir ANTES da navegação.
		const entrouA = joinDaAgenda(page, clinica.dia);
		const entrouB = joinDaAgenda(abaB, clinica.dia);

		await abrirAgenda(page, clinica);
		await abrirAgenda(abaB, clinica);
		await Promise.all([entrouA, entrouB]);

		await expect(blocos(page)).toHaveCount(0);
		await expect(blocos(abaB)).toHaveCount(0);

		// A escrita vem de fora das duas abas — é o caso real: outra pessoa (ou outro dispositivo)
		// marcou. Nenhuma das duas telas sabe que isso aconteceu, a não ser pelo canal.
		const agendamento = await criarAgendamento(clinica.api, {
			starts_at: instanteUtc(clinica.dia, '10:00'),
			professional_id: clinica.profissional.id,
			appointment_type_id: clinica.tipo.id,
			patient_ids: [clinica.paciente.id]
		});

		const rotulo = `10:00 · ${clinica.paciente.nome} · ${clinica.tipo.nome} · Agendado`;
		await expect(blocos(page)).toHaveAttribute('aria-label', rotulo);
		await expect(blocos(abaB)).toHaveAttribute('aria-label', rotulo);

		// Nenhuma das duas navegou: se o bloco está aí, veio pelo socket. (Uma recarga acidental
		// mascararia o teste inteiro — daí a asserção sobre a URL, que segue a mesma.)
		await expect(page).toHaveURL(new RegExp(`/agenda\\?date=${clinica.dia}$`));

		// A outra ponta do canal: a EXCLUSÃO só empurra o id (o servidor esconde o bloco), e é por
		// isso que ela tem caminho próprio no cliente (`onRemove`). Sem ele, o bloco excluído fica
		// na tela de quem não recarregou — o "bloco fantasma" do doc 40.
		const excluido = await clinica.api.post(`/api/appointments/${agendamento.id}/exclude`, {
			data: { expected_version: agendamento.version }
		});
		expect(excluido.ok()).toBe(true);

		await expect(blocos(page)).toHaveCount(0);
		await expect(blocos(abaB)).toHaveCount(0);
	});
});
