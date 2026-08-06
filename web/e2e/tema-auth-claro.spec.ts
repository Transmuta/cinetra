// `test` vem das fixtures pela guarda compartilhada (stack fora do ar falha em vez de pular em
// silêncio). Só o terceiro caso precisa da stack; os dois primeiros são páginas públicas.
import { test, expect, type Page } from '@playwright/test';
import { test as testComStack } from './fixtures';
import { emailUnico, entrar } from './helpers';

/**
 * Entrada, cadastro, onboarding — e a tela do paciente — ignoram o tema escuro.
 *
 * As três primeiras por pedido de 2026-07-30; a `/confirmar` entrou depois, e nela o custo era
 * maior: o paciente chega de um e-mail em papel creme e **nunca** tem cookie de tema, então quem
 * decidia era o `prefers-color-scheme` do aparelho. Quem lê no escuro abria uma página quase preta
 * a um clique de um e-mail claro — duas marcas para a mesma mensagem.
 *
 * Estas telas são o protótipo papel/navy da Cinetra — cor de MARCA, não superfície de app.
 * O `AuthCard` fixa `data-theme="light"` no próprio nó e o `app.css` re-declara ali os tokens
 * claros, então tudo que está dentro resolve pelo claro mesmo com o `<html>` no escuro.
 *
 * Precisa ser e2e: quem faz o trabalho é a **cascata de custom properties**, e nem o jsdom do
 * Vitest a resolve nem um teste de componente enxergaria o `<html>`. O que quebrava de verdade
 * era o `/comecar`, o único dos três que usa os controles do design system (`Field`, `Button`)
 * em vez dos hex do protótipo: no escuro, o card era de papel e o campo dentro dele, quase-preto.
 *
 * Os dois caminhos do tema são cobertos: `colorScheme: 'dark'` é o `prefers-color-scheme` de quem
 * nunca escolheu (nenhum atributo no `<html>`), e o cookie `mv-theme=dark` é a escolha explícita
 * que o `hooks.server` estampa no HTML servido.
 */

// Tema claro, verbatim do app.css.
const SURFACE_CLARA = '#ffffff';
const TEXTO_CLARO = '#161a1e';
// Tema escuro — só como sanidade: se o <html> não estiver escuro, o teste não prova nada.
const CANVAS_ESCURO = '#0c0d0e';

/**
 * Uma custom property, como o browser a resolve NAQUELE nó.
 *
 * Normaliza o hex de 3 dígitos: o minificador do build encurta `#ffffff` para `#fff`, e o
 * `getPropertyValue` devolve o texto verbatim — a comparação crua reprovava a cor certa.
 */
async function token(page: Page, seletor: string, nome: string): Promise<string> {
	const valor = await page
		.locator(seletor)
		.first()
		.evaluate((el, n) => getComputedStyle(el).getPropertyValue(n).trim(), nome);

	return /^#[0-9a-f]{3}$/i.test(valor)
		? '#' + [...valor.slice(1)].map((c) => c + c).join('')
		: valor;
}

test.describe('Entrada, cadastro e tela do paciente no escuro do sistema', () => {
	test.use({ colorScheme: 'dark' });

	// `/confirmar` com token inválido: é o estado que não precisa de stack nem de mensagem no
	// banco, e a moldura (`CartaoPaciente`) é a mesma dos outros estados da tela.
	for (const rota of ['/entrar', '/criar-conta', '/confirmar/token-invalido']) {
		test(`${rota}: o <html> está no escuro e a tela continua clara`, async ({ page }) => {
			await page.goto(rota);

			// Sanidade: sem isto, o dia em que o dark mode parasse de ser aplicado deixaria as
			// asserções abaixo verdes por acidente.
			expect(await token(page, 'html', '--mv-canvas')).toBe(CANVAS_ESCURO);

			expect(await token(page, '.cn-root', '--mv-surface')).toBe(SURFACE_CLARA);
			expect(await token(page, '.cn-root', '--mv-text')).toBe(TEXTO_CLARO);

			// `color-scheme` é o par obrigatório do atributo: sem ele o browser continua pintando
			// no escuro as superfícies que ele mesmo desenha (scrollbar, autofill, seletor nativo).
			const colorScheme = await page
				.locator('.cn-root')
				.first()
				.evaluate((el) => getComputedStyle(el).colorScheme);
			expect(colorScheme).toBe('light');
		});
	}
});

testComStack(
	'/comecar: os controles do onboarding ficam claros mesmo com mv-theme=dark',
	async ({ page, request, context }) => {
		await page.goto('/');
		await context.addCookies([{ name: 'mv-theme', value: 'dark', url: page.url() }]);

		await entrar(page, request, emailUnico('tema-auth'));
		// Quem entra sem clínica cai no onboarding.
		await expect(page.getByLabel('Nome da clínica')).toBeVisible();
		await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');

		// O campo é `bg-surface` e o botão é `bg-primary`: no escuro seriam quase-preto e
		// quase-branco (com texto escuro). Dentro do card de papel têm de ser os do claro.
		await expect(page.getByLabel('Nome da clínica')).toHaveCSS(
			'background-color',
			'rgb(255, 255, 255)'
		);

		const botao = page.getByRole('button', { name: 'Criar clínica' });
		await expect(botao).toHaveCSS('background-color', 'rgb(22, 24, 28)'); // --mv-primary claro
		await expect(botao).toHaveCSS('color', 'rgb(255, 255, 255)'); // --mv-on-primary claro
	}
);
