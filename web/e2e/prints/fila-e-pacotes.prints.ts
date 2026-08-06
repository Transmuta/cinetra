import { test, expect } from './autenticado';
import { foto } from './foto';

// Fila de espera e pacotes — as duas fatias que mais dependem de imagem, porque o texto sozinho
// não explica uma grade semanal nem uma lista de vagas compatíveis.
//
// Os diálogos são pegos por `getByRole('dialog')` sem nome: o `Modal` do projeto desenha o título
// como texto, não como nome acessível, então casar por nome não encontra nada. Só o `Drawer` do
// agendamento tem `aria-label`.

test('fila de espera', async ({ page, clinica }) => {
	// `?novo=1` é o gatilho DOCUMENTADO da tela: "Adicionar à fila" mora na sidebar e é um `<a>`
	// que navega para cá — não um `<button>`. Foi o que segurou esta print por uma leva inteira:
	// `getByRole('button', …)` nunca casa com um link, e a espera morria no timeout sem dizer isso.
	await page.goto('/fila?novo=1');
	await page.waitForLoadState('networkidle');

	const modal = page.getByRole('dialog');
	await expect(modal).toBeVisible();
	await foto(modal, 'fila-adicionar-01', { assentar: 300 });

	// A disponibilidade fica mais abaixo, no mesmo formulário.
	const disponibilidade = modal
		.getByText('Disponibilidade do paciente')
		.locator('xpath=ancestor::*[2]');
	if (await disponibilidade.isVisible().catch(() => false)) {
		await disponibilidade.scrollIntoViewIfNeeded();
		await foto(disponibilidade, 'fila-adicionar-02');
	}

	// Agora criar de verdade, para a lista e a oferta terem o que mostrar.
	const buscar = modal.getByRole('combobox', { name: 'Buscar paciente' });
	const primeiroNome = clinica.paciente.nome.split(' ')[0];
	await buscar.fill(primeiroNome);
	// Pelo NOME e não por `.first()`: a lista só ganha opções depois que a busca volta do servidor,
	// e o `.first()` pegava a caixa ainda vazia — "element is not visible" em laço até o timeout.
	// Esperar a opção com o nome dentro é esperar o resultado, não o elemento.
	await modal.getByRole('option', { name: new RegExp(primeiroNome) }).first().click();
	await modal.getByRole('button', { name: /Adicionar|Salvar/ }).last().click();

	await expect(modal).toBeHidden();
	await expect(page.getByText(clinica.paciente.nome).first()).toBeVisible();
	// A coluna "Espera" conta a partir do instante do cadastro: sem máscara, toda regeneração
	// mudaria a imagem sem que nada tivesse mudado na tela.
	await foto(page, 'fila-lista-01', {
		assentar: 300,
		mask: [page.getByText(/^há |^agora|min$/).first()]
	});

	// "Oferecer" (exato) é a linha do DESKTOP; "Oferecer vaga" é o cartão do celular, que a 1440px
	// não existe. As duas formas convivem na mesma tela e só uma está visível por vez.
	await page.getByRole('button', { name: 'Oferecer', exact: true }).first().click();
	const oferta = page.getByRole('dialog');
	await expect(oferta).toBeVisible();
	await foto(oferta, 'fila-oferecer-01', { assentar: 800 });
});

test('pacotes', async ({ page, clinica }) => {
	await page.goto(`/pacientes/${clinica.paciente.id}`);
	await page.waitForLoadState('networkidle');
	await page.getByRole('button', { name: 'Novo pacote' }).first().click();

	const modal = page.getByRole('dialog');
	await expect(modal).toBeVisible();
	await foto(modal, 'pacotes-novo-01', { assentar: 300 });

	const grade = modal.getByRole('group', { name: 'Grade semanal' });
	await expect(grade).toBeVisible();
	// Marca dois dias para a grade e a prévia terem conteúdo — grade vazia não ensina nada.
	await grade.getByRole('button').nth(2).click();
	await grade.getByRole('button').nth(4).click();
	await foto(grade, 'pacotes-grade-01', { assentar: 300 });

	const previa = modal.getByText('Prévia da série').locator('xpath=ancestor::*[2]');
	await expect(previa).toBeVisible();
	await foto(previa, 'pacotes-previa-01', { assentar: 400 });

	await modal.getByRole('button', { name: /Criar|Salvar/ }).last().click();

	// O cartão do pacote, já na ficha.
	const cartao = page.getByText(/Sessões|pacote/i).first().locator('xpath=ancestor::section[1]');
	await expect(cartao).toBeVisible({ timeout: 20_000 });
	await foto(cartao, 'pacotes-cartao-01', { assentar: 600 });

	await page.getByRole('button', { name: 'Gerir pacote' }).first().click();
	await foto(page.getByRole('menu').or(cartao), 'pacotes-menu-01', { assentar: 300 });

	// "Ver sessões" é item do MESMO menu — o cartão informa, o menu executa. Aproveita o menu
	// aberto em vez de fechar e reabrir: o Esc NÃO fecha este menu (quem fecha é o backdrop), e
	// tentar reabrir com ele aberto caía no backdrop invisível interceptando o clique — o teste
	// ficava seis minutos "tentando clicar" num botão visível e aparentemente alcançável.
	await page.getByRole('button', { name: 'Ver sessões' }).click();
	const modalSessoes = page.getByRole('dialog');
	await expect(modalSessoes).toBeVisible();
	await foto(modalSessoes, 'pacotes-sessoes-01', { assentar: 900 });
});
