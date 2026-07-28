import { test, expect } from './fixtures';

/**
 * Varredura do shell: nenhuma tela pode acusar erro no console, e a CSP tem de estar no ar.
 *
 * É o teste mais barato desta leva e cobre duas classes que nenhuma outra camada alcança:
 *
 *  1. **CSP.** Ela é assada no BUILD (`kit.csp` → `connect-src`), então só existe num app buildado
 *     — que é o que o e2e roda (`build` + `preview`). Uma origem faltando ali não quebra servidor
 *     nenhum: bloqueia o WebSocket ou o upload do anexo, e escreve o motivo só no console de quem
 *     está usando. Aqui isso vira build vermelho.
 *
 *  2. **Link de `<a>` para endpoint `+server`.** Sem `data-sveltekit-reload` o roteador de cliente
 *     tenta resolvê-lo como página e devolve 404 — o bug do botão do Google. Ele não aparece no
 *     SSR nem em teste de componente: precisa de navegação de cliente, que é o que acontece ao
 *     percorrer as rotas abaixo com o app já hidratado.
 *
 * A lista é o shell inteiro de propósito. Uma tela nova entra aqui em uma linha, e passa a ter pelo
 * menos a garantia de que abre sem gritar.
 */
const ROTAS = [
	'/agenda',
	'/agenda?view=semana',
	'/agenda?view=mes',
	'/agenda?view=lista',
	'/pacientes',
	'/profissionais',
	'/fila',
	'/relatorios',
	'/auditoria',
	'/notificacoes',
	'/configuracoes/equipe',
	'/configuracoes/clinica',
	'/configuracoes/horario',
	'/configuracoes/excecoes',
	'/configuracoes/tipos',
	'/perfil'
];

test.describe('Varredura do shell', () => {
	test('todas as telas abrem sem erro de console e com CSP no ar', async ({ page, clinica }) => {
		const problemas: string[] = [];
		let rotaAtual = '/';

		// Violação de CSP chega ao Chromium como erro de console ("Refused to connect to …"), então
		// esta escuta cobre as duas coisas de uma vez.
		page.on('console', (msg) => {
			if (msg.type() === 'error') problemas.push(`${rotaAtual} — console: ${msg.text()}`);
		});
		page.on('pageerror', (erro) => {
			problemas.push(`${rotaAtual} — exceção: ${erro.message}`);
		});

		for (const rota of ROTAS) {
			rotaAtual = rota;
			const res = await page.goto(rota);

			// Nada de 403/500 disfarçado de tela: o shell inteiro é acessível ao owner.
			expect(res?.status(), `${rota} respondeu ${res?.status()}`).toBe(200);

			// O cromo é a prova de que a tela renderizou (e não a página de erro, que não o tem).
			await expect(page.getByRole('navigation', { name: 'Navegação principal' })).toBeVisible();

			// A CSP sai do SvelteKit no header da NAVEGAÇÃO. Conferir a origem do socket aqui é o que
			// pega a divergência build × runtime antes de ela virar "a agenda parou de atualizar".
			const csp = res?.headers()['content-security-policy'] ?? '';
			expect(csp, `${rota} veio sem CSP`).toContain("connect-src 'self'");
			expect(csp).toMatch(/connect-src[^;]*\bwss?:\/\//);

			// Hidratar pode gritar depois do `load` (efeito, fetch, socket). Sem esta folga o teste
			// mediria só o SSR, que é a metade que raramente quebra.
			await page.waitForTimeout(400);
		}

		expect(problemas, `erros de console no shell:\n${problemas.join('\n')}`).toEqual([]);
	});
});
