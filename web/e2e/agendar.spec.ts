import { test, expect, abrirAgenda, blocos } from './fixtures';
import { instanteUtc } from './helpers';

/**
 * A jornada central do produto: a recepção clica num vazio da grade e sai com o bloco na tela.
 *
 * Por que ela merece um e2e, com 147 arquivos de Vitest já cobrindo as peças. Duas razões, e as
 * duas só existem contra a stack de verdade:
 *
 *  1. **É o caminho mais rico de RLS.** Cada passo aqui lê ou escreve por tenant, e o servidor de
 *     verdade conecta como `cinetra_app` (NOBYPASSRLS). Um `in_clinic` esquecido devolve lista
 *     VAZIA ali e verde no `mix test`, que conecta como superusuário — a classe de bug que já
 *     mordeu três vezes na fatia Agenda. O job `api-rls` do CI só cobre o subconjunto marcado
 *     `@tag :rls`; aqui o caminho HTTP inteiro está sob o mesmo role.
 *
 *  2. **A conversão de fuso não tem outro juiz.** O modal converte "relógio da clínica → instante"
 *     no cliente (`toUtcIso`), e o erro é invisível numa máquina que rode em UTC — que é
 *     exatamente o container onde tudo isto roda. A última asserção compara o `starts_at` gravado
 *     com o instante calculado **independentemente** pelo teste (`instanteUtc`, `helpers.ts`): se
 *     alguém trocar a conversão por um `new Date(...)` ingênuo, este é o teste que fica vermelho.
 */
test.describe('Agendar pela grade', () => {
	test('do clique no vazio ao bloco desenhado, no horário certo', async ({ page, clinica }) => {
		await abrirAgenda(page, clinica);
		await expect(blocos(page)).toHaveCount(0);

		// O caminho real de abrir o modal: clicar no corpo da coluna do profissional. A hora sai da
		// geometria do clique (arredondada de 15 em 15) — o campo abaixo a fixa, para o teste não
		// depender de pixel.
		await page
			.locator(`[data-prof-id="${clinica.profissional.id}"] [data-column-body]`)
			.click({ position: { x: 40, y: 80 } });

		const modal = page.getByRole('dialog', { name: 'Novo agendamento' });
		await expect(modal).toBeVisible();

		// Busca com ≥2 caracteres e debounce de 300ms (PatientPicker): o resultado é assíncrono, e é
		// o `expect` que espera por ele.
		await modal.getByRole('combobox', { name: 'Buscar paciente' }).fill('Marina');
		// `option`, não `button`: a lista do `PatientPicker` é um listbox ARIA 1.2 (cada resultado é
		// um `<li role="option">`). Enquanto o build do preview estava velho, este teste passava
		// procurando `button` — verde contra um app que não existia mais.
		await modal.getByRole('option', { name: /Marina Prado/ }).click();

		await modal.getByLabel('Tipo').selectOption({ label: `${clinica.tipo.nome} (50min)` });
		await modal.getByLabel('Hora').fill('09:00');

		await modal.getByRole('button', { name: 'Agendar' }).click();

		// O sucesso fecha o modal e avisa (o load já reexecutou — o grid abaixo é dado do servidor).
		await expect(page.getByText('Agendamento criado')).toBeVisible();
		await expect(modal).toBeHidden();

		// O bloco, com o rótulo que o componente monta: hora · paciente · tipo · situação.
		await expect(blocos(page)).toHaveCount(1);
		await expect(blocos(page)).toHaveAttribute(
			'aria-label',
			`09:00 · ${clinica.paciente.nome} · ${clinica.tipo.nome} · Agendado`
		);

		// E o que o servidor gravou de fato. 09:00 na clínica (UTC−3) é 12:00Z — se a conversão do
		// modal cair, o bloco continua desenhando "09:00" (ele relê o mesmo fuso) e só esta linha
		// acusa.
		const res = await clinica.api.get(
			`/api/appointments?from=${clinica.dia}&to=${clinica.dia}`
		);
		expect(res.ok()).toBe(true);

		const { appointments } = (await res.json()) as { appointments: { starts_at: string }[] };
		expect(appointments).toHaveLength(1);
		expect(Date.parse(appointments[0].starts_at)).toBe(
			Date.parse(instanteUtc(clinica.dia, '09:00'))
		);
	});
});
