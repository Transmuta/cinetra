import type { Page } from '@playwright/test';
import { test, expect, abrirAgenda, blocos } from './fixtures';
import { criarAgendamento } from './helpers';

/**
 * §13 (robustez) e §14 (mobile/teclado) do roteiro de QA guiado (doc 82).
 *
 * São os cenários que a Andreza pediu e que nenhum teste do repositório cobria: rede caindo no
 * meio do trabalho, duplo clique, e a tela em 200% de zoom. Ficam separados do `roteiro82.spec.ts`
 * porque mexem no **contexto** do browser (offline, viewport, CPU), e não só na página.
 */

function drawer(page: Page) {
	return page.getByRole('dialog');
}

/** Deixa a página offline de verdade (camada de rede do Chromium, como o DevTools faz). */
async function offline(page: Page, ligado: boolean) {
	await page.context().setOffline(ligado);
}

/**
 * Preenche nome + telefone da ficha **depois que o cliente assumiu a página**.
 *
 * A máscara é o sinal de hidratação, e é o único honesto aqui: o formulário vem pronto do SSR,
 * então `toBeVisible` passa na hora e o `fill` acerta um DOM **sem handler** — o valor entra, o
 * estado do Svelte não muda, e o botão fica `disabled` para sempre. Só quando o `oninput` está
 * ligado é que `11987775544` vira `(11) 98777-5544`. O `toPass` repete o preenchimento até lá.
 */
async function preencherMinimo(page: Page, nome: string, tel = '11987775544') {
	const campoTel = page.getByRole('textbox', { name: 'Telefone / WhatsApp*' });
	const campoNome = page.getByRole('textbox', { name: /Nome completo/ });

	await expect(async () => {
		await campoTel.fill(tel);
		await expect(campoTel).toHaveValue(/\(\d{2}\)\s/, { timeout: 1_000 });
	}).toPass({ timeout: 30_000 });

	await campoNome.fill(nome);
	await expect(page.getByRole('button', { name: /Cadastrar paciente/ })).toBeEnabled();
}

test.describe('Roteiro 82 · §13 robustez', () => {
	/**
	 * Reprovava quando o QA guiado o escreveu (doc 88, A-10) e passou a valer com o conserto.
	 *
	 * O que estava errado: salvar a ficha com a rede fora trocava o formulário inteiro pela página
	 * `500 — Algo deu errado / Failed to fetch`, e tudo o que fora digitado ia junto. Três defeitos
	 * no mesmo sintoma — falha de REDE virando "500", mensagem interna do browser na cara do
	 * usuário, e a perda do trabalho.
	 *
	 * A causa era o `update()` do `use:enhance`: ele chama o `applyAction`, que para
	 * `result.type === 'error'` **substitui a página**. O conserto mora em `$lib/forms.svelte`
	 * (`ERRO_DE_REDE`) e vale para todos os formulários; aqui o teste guarda o comportamento pela
	 * ponta que interessa — o campo continua preenchido.
	 */
	test('offline ao salvar paciente: erro civilizado e o que foi digitado NÃO se perde', async ({
		page,
		clinica
	}) => {
		expect(clinica.id).toBeTruthy();
		await page.goto('/pacientes/novo');
		const cpf = page.getByRole('textbox', { name: 'CPF' });
		await expect(cpf).toBeVisible();

		const nome = 'Paciente Offline QA';
		await preencherMinimo(page, nome);

		await offline(page, true);
		await page.getByRole('button', { name: /Cadastrar paciente/ }).click();

		// 1) a recusa é civilizada: nem tela de 500, nem a mensagem interna do browser…
		await expect(page.getByText(/Sem conexão com o servidor/)).toBeVisible();
		await expect(page.locator('body')).not.toContainText('Failed to fetch');
		await expect(page.locator('body')).not.toContainText('Algo deu errado');
		// 2) …e o digitado continua lá, que é o dano que importava.
		await expect(page.getByRole('textbox', { name: /Nome completo/ })).toHaveValue(nome);

		await offline(page, false);
	});

	test('duplo clique em "Cadastrar paciente" cria UMA ficha só', async ({ page, clinica }) => {
		await page.goto('/pacientes/novo');
		const cpf = page.getByRole('textbox', { name: 'CPF' });
		await expect(cpf).toBeVisible();

		const nome = `Duplo Clique ${Date.now()}`;
		await preencherMinimo(page, nome, '11987775500');

		const salvar = page.getByRole('button', { name: /Cadastrar paciente/ });
		// Dois cliques no mesmo tick — é o que o dedo nervoso faz.
		await Promise.all([salvar.click(), salvar.click().catch(() => {})]);
		await page.waitForLoadState('networkidle');

		// A autoridade é o servidor, não a tela: quantas fichas com esse nome existem?
		const res = await clinica.api.get(`/api/patients?q=${encodeURIComponent(nome)}`);
		const { patients } = (await res.json()) as { patients: Array<{ nome: string }> };
		expect(patients.filter((p) => p.nome === nome)).toHaveLength(1);
	});

	test('F5 com o drawer aberto volta ao mesmo estado (o link sobrevive)', async ({
		page,
		clinica
	}) => {
		await criarAgendamento(clinica.api, {
			starts_at: `${clinica.dia}T09:00:00-03:00`,
			professional_id: clinica.profissional.id,
			appointment_type_id: clinica.tipo.id,
			patient_ids: [clinica.paciente.id]
		});

		await abrirAgenda(page, clinica);
		await blocos(page).first().click();
		await expect(drawer(page)).toBeVisible();

		const url = page.url();
		expect(url).toContain('agendamento=');

		await page.reload();
		await expect(drawer(page)).toBeVisible();
	});
});

test.describe('Roteiro 82 · §14 mobile e zoom', () => {
	test.use({ viewport: { width: 390, height: 844 } });

	test('a agenda no celular: sem rolagem horizontal e com o drawer cobrindo a tela', async ({
		page,
		clinica
	}) => {
		await criarAgendamento(clinica.api, {
			starts_at: `${clinica.dia}T09:00:00-03:00`,
			professional_id: clinica.profissional.id,
			appointment_type_id: clinica.tipo.id,
			patient_ids: [clinica.paciente.id]
		});

		// `abrirAgenda` espera o pedido do token do WebSocket — a prova barata de que a página já
		// responde a evento. Sem isso o clique no bloco acerta um DOM sem handler e some.
		await abrirAgenda(page, clinica);

		// O corpo da página não pode rolar na horizontal (a grade rola dentro dela mesma).
		const transborda = await page.evaluate(
			() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1
		);
		expect(transborda).toBe(false);

		// O §6 exige que o DIA esteja no drawer — no celular ele cobre o cabeçalho.
		await blocos(page).first().click();
		await expect(drawer(page)).toBeVisible();
		await expect(drawer(page)).toContainText(/\d{2}:\d{2}/);
	});

	test('a fórmula do KPI abre no TOQUE, não só no hover (ACC-10)', async ({ page, clinica }) => {
		expect(clinica.id).toBeTruthy();
		await page.goto('/relatorios');

		const ajuda = page.getByRole('button', { name: /Como .* é calculado/ }).first();
		await expect(ajuda).toBeVisible();

		// `toPass` no lugar de um clique só: o botão vem do SSR e o `onclick` só existe depois da
		// hidratação — o primeiro toque pode cair no vazio, sem erro nenhum.
		await expect(async () => {
			await ajuda.click();
			await expect(page.getByText(/Como calculamos:/)).toBeVisible({ timeout: 1_000 });
		}).toPass({ timeout: 30_000 });
	});
});

test.describe('Roteiro 82 · §14 zoom 200%', () => {
	// 200% de zoom em 1280×720 equivale a metade da área CSS.
	test.use({ viewport: { width: 640, height: 360 } });

	test('login e agenda continuam operáveis, sem rolagem horizontal', async ({ page, clinica }) => {
		for (const destino of ['/entrar', `/agenda?date=${clinica.dia}`]) {
			await page.goto(destino);
			const transborda = await page.evaluate(
				() => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1
			);
			expect(transborda, `${destino} transbordou na horizontal`).toBe(false);
		}
	});
});
