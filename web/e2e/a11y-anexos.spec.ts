import fs from 'node:fs';
import { test, expect } from './fixtures';

/**
 * O upload de anexo tem caminho de teclado?
 *
 * A auditoria do AN-08 (doc 80, item 8) registrou a dúvida assim: "dar caminho de teclado ao
 * upload (**já existe o input de arquivo**; conferir a ordem)". Esta sonda confere — e a
 * pergunta importa porque `display:none` tira o elemento da ordem de tabulação inteira, não só
 * da tela. Se o único gatilho for a `<label>` (que não é focável) e o input estiver escondido
 * assim, não há caminho nenhum: WCAG 2.1.1, nível A.
 */

test('a zona de upload de anexo é alcançável por teclado?', async ({ page, clinica }) => {
	test.setTimeout(120_000);

	await page.goto(`/pacientes/${clinica.paciente.id}`);
	await page.waitForLoadState('networkidle');

	const medida = await page.evaluate(() => {
		const input = document.querySelector('input[type="file"]');
		const sel =
			'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select, textarea, [tabindex]:not([tabindex="-1"])';

		// A seção dos anexos: o container do input de arquivo (ou da mensagem que o substitui).
		const secao = input?.closest('section') ?? null;

		return {
			temInputDeArquivo: !!input,
			displayDoInput: input ? getComputedStyle(input).display : null,
			classeDoInput: input?.getAttribute('class') ?? null,
			// `offsetParent === null` + display none ⇒ o browser não o inclui na tabulação.
			inputRenderizado: input ? !!(input as HTMLElement).offsetParent : null,
			focaveisNaSecaoDeAnexos: secao
				? [...secao.querySelectorAll(sel)].map((e) =>
						(e.getAttribute('aria-label') || e.textContent || e.tagName).trim().slice(0, 45)
					)
				: null,
			// A label é o gatilho de mouse: ela é focável?
			labelDaZona: (() => {
				const l = input?.closest('label');
				if (!l) return null;
				return { tabIndex: (l as HTMLElement).tabIndex, focavel: (l as HTMLElement).tabIndex >= 0 };
			})()
		};
	});

	console.log(JSON.stringify(medida, null, 1));
	fs.writeFileSync('a11y-anexos.json', JSON.stringify(medida, null, 1));

	// Sonda de auditoria: não barra. Mas se o input nem existe, a medida não vale nada.
	expect(medida.temInputDeArquivo).toBe(true);
});
