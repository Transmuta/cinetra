import { test, expect, abrirAgenda, blocos } from './fixtures';
import { criarAgendamento, instanteUtc } from './helpers';

/**
 * O link do agendamento: abrir o drawer muda a URL, e a URL abre o drawer.
 *
 * Três coisas aqui **só existem no browser de verdade** — nenhuma unidade as alcança:
 *
 *  1. **Shallow routing não reexecuta o load.** O load da agenda lê `url.searchParams`, então
 *     `goto` refaria a busca do dia inteiro (agenda + expediente de todas as colunas) a cada
 *     bloco aberto. `pushState`/`replaceState` de `$app/navigation` mudam a URL sem load nenhum,
 *     e o que prova isso é a AUSÊNCIA de requisição — contada na rede, não mockada. Um mock de
 *     `$app/navigation` diria "chamei pushState" com a mesma cara se o SvelteKit tivesse mudado
 *     de contrato.
 *  2. **O back fecha o drawer.** Depende do histórico real do browser.
 *  3. **O link canônico resolve o dia.** `/agenda?agendamento=<id>` sem `date` só abre porque o
 *     servidor lê o bloco por id e descobre o dia dele — e o teste usa um horário cujo dia local
 *     ≠ dia UTC, que é onde a conversão erra quando erra.
 */
test.describe('Link do agendamento', () => {
	test('abrir o drawer muda a URL sem recarregar a agenda; o back fecha', async ({
		page,
		clinica
	}) => {
		const agendamento = await criarAgendamento(clinica.api, {
			starts_at: instanteUtc(clinica.dia, '14:00'),
			professional_id: clinica.profissional.id,
			appointment_type_id: clinica.tipo.id,
			patient_ids: [clinica.paciente.id]
		});

		await abrirAgenda(page, clinica);
		await expect(blocos(page)).toHaveCount(1);

		// A partir daqui, qualquer leitura da agenda pelo BFF é reexecução de load — é isto que o
		// shallow routing existe para evitar.
		const recargas: string[] = [];
		page.on('request', (r) => {
			if (/__data\.json|\/api\/appointments\?/.test(r.url())) recargas.push(r.url());
		});

		await blocos(page).click();

		const drawer = page.getByRole('dialog', { name: 'Detalhes do agendamento' });
		await expect(drawer).toBeVisible();

		// A URL passou a dizer o que está aberto — com a data junto, que é o que fixa o dia.
		await expect(page).toHaveURL(new RegExp(`agendamento=${agendamento.id}`));
		await expect(page).toHaveURL(new RegExp(`date=${clinica.dia}`));

		expect(recargas).toEqual([]);

		// O back fecha o painel (abrir empilha) — e a URL larga o id.
		await page.goBack();
		await expect(drawer).toBeHidden();
		await expect(page).not.toHaveURL(/agendamento=/);
		// E fechar pelo back também não custou uma recarga da agenda.
		expect(recargas).toEqual([]);
	});

	// Sem `date` na URL: é o servidor que lê o bloco por id e descobre o dia dele. O cenário usa um
	// dia que NÃO é hoje, senão o teste passaria mesmo sem resolução nenhuma (o load cai no hoje da
	// clínica quando não há data).
	//
	// A borda do dia (bloco de 22h, cujo dia UTC é o seguinte) fica no teste do load, com fuso
	// mockado: a API recusa criar agendamento fora do expediente — nem como encaixe, que é
	// bloqueio absoluto (D14) — então ela não é montável por aqui.
	test('o link canônico (sem data) abre o drawer no dia do bloco', async ({ page, clinica }) => {
		const agendamento = await criarAgendamento(clinica.api, {
			starts_at: instanteUtc(clinica.dia, '15:00'),
			professional_id: clinica.profissional.id,
			appointment_type_id: clinica.tipo.id,
			patient_ids: [clinica.paciente.id]
		});

		await page.goto(`/agenda?agendamento=${agendamento.id}`);

		await expect(page.getByRole('dialog', { name: 'Detalhes do agendamento' })).toBeVisible();
		await expect(page.getByTestId('drawer-titulo')).toHaveText(clinica.paciente.nome);
		// A agenda embaixo é a do dia do bloco: `clinica.dia` é sempre no futuro, então a agenda de
		// hoje estaria vazia.
		await expect(blocos(page)).toHaveCount(1);
		// E **sem redirect**: a URL continua a canônica. Um 302 para o dia do bloco resolveria o
		// link do mesmo jeito, mas faria a tela pular de data sozinha depois de uma remarcação.
		await expect(page).toHaveURL(`/agenda?agendamento=${agendamento.id}`);
	});

	test('link para um agendamento que não existe abre a agenda, não um erro', async ({
		page,
		clinica
	}) => {
		const erros: string[] = [];
		page.on('pageerror', (e) => erros.push(e.message));
		page.on('console', (m) => m.type() === 'error' && erros.push(m.text()));

		await page.goto(`/agenda?agendamento=019fab71-0000-7000-8000-000000000000`);

		// A agenda carrega (o cabeçalho da coluna do profissional aparece) e nada de drawer.
		await expect(page.locator(`[data-prof-id="${clinica.profissional.id}"]`)).toBeVisible();
		await expect(page.getByRole('dialog', { name: 'Detalhes do agendamento' })).toBeHidden();
		// E sem erro nenhum no console: o parâmetro órfão fica na URL de propósito — limpá-lo aqui
		// exigiria shallow routing na hidratação, que é justamente quando o roteador ainda não
		// iniciou ("Cannot call replaceState(...) before router is initialized").
		expect(erros).toEqual([]);
	});
});
