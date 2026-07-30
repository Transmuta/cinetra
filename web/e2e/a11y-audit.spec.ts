import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import fs from 'node:fs';

/**
 * O gate de acessibilidade das páginas **públicas** — landing, autenticação e documentos legais.
 *
 * Nasceu como auditoria no AN-08 (doc 64, D8: auditar → consertar → só então barrar, já verde).
 * As duas primeiras etapas estão feitas: os achados de contraste daquela rodada foram consertados
 * e a varredura está em zero, então agora ela **barra**.
 *
 * As telas autenticadas têm gate próprio em `a11y-interno.spec.ts` (elas precisam de sessão, e o
 * caminho é o magic link da caixa de dev).
 */

const PAGINAS = ['/', '/entrar', '/criar-conta', '/privacidade', '/termos'];

interface Achado {
	pagina: string;
	id: string;
	impact: string | null | undefined;
	description: string;
	nodes: number;
	alvo: string[];
}

test('varredura axe nas páginas públicas', async ({ page }) => {
	test.setTimeout(120_000);

	const achados: Achado[] = [];

	for (const url of PAGINAS) {
		await page.goto(url);
		await page.waitForLoadState('networkidle');

		const results = await new AxeBuilder({ page })
			.withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
			.analyze();

		for (const v of results.violations) {
			achados.push({
				pagina: url,
				id: v.id,
				impact: v.impact,
				description: v.description,
				nodes: v.nodes.length,
				alvo: v.nodes.slice(0, 3).map((n) => n.target.join(' ')),
				html: v.nodes.slice(0, 3).map((n) => n.html.slice(0, 160)),
				resumo: v.nodes[0]?.failureSummary?.slice(0, 300)
			});
		}
	}

	fs.writeFileSync('a11y-report.json', JSON.stringify(achados, null, 1));
	console.log(`axe: ${achados.length} violações — ver a11y-report.json`);

	// Regra + página + alvo na mensagem, para a falha dizer onde olhar (o relatório completo fica
	// no JSON). Baixar o gate não é opção — ver `.claude/rules/testes.md`.
	expect(
		achados.map((a) => `${a.id} @ ${a.pagina} (${a.nodes}×) — ${a.alvo[0] ?? '?'}`),
		'violações de acessibilidade nas páginas públicas'
	).toEqual([]);
});
